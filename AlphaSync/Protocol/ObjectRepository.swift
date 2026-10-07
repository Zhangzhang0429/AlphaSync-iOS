import Foundation

/// 对象访问层（PTP/IP 版）—— 镜像安卓端 `ObjectRepository.kt`。
///
/// - 控制面：长连接 PtpIpClient（已认证会话 + 事件连接），按 host 登记在 sessions；
/// - 数据面：每次对象传输新建 DataChannel 走独立文件端口，用完即关；
/// - 元数据（LIST_DIR / STAT / PING / DEVICE_INFO）：内联在控制面响应里。
///
/// LIST_DIR 的 blob 契约（厂商 JSON，UTF-8）：
/// ```json
/// {"dir":"/DCIM","entries":[
///   {"name":"100MSDCF","dir":true,"size":0,"mtime":0},
///   {"name":"DSC00001.JPG","dir":false,"size":5242880,"mtime":1757500000000}
/// ], "hasMore": false, "nextOffset": 12}
/// ```
/// 为兼容早期实现也接受裸数组。
final class ObjectRepository {

    static let shared = ObjectRepository()

    private let connectTimeoutMs = 5000
    private let pairTimeoutMs = 20000
    private let ioTimeoutMs = 30000
    private let listTimeoutMs = 15000
    static let scanListTimeoutMs = 30000
    private let dirCountProbeOffset = 1_000_000_000
    static let batchItemLimit = 32

    // 控制面串行队列（相机按 deviceId 识别 initiator，同一 deviceId 的第二条控制连接会踢掉前一条）
    private let ioQueue = DispatchQueue(label: "alphasync.ptpip.io")
    // 数据面单线程队列（整对象搬运）
    private let xferQueue = DispatchQueue(label: "alphasync.ptpip.xfer")

    final class Session {
        let host: String
        let protoPort: Int
        let client: PtpIpClient
        init(host: String, protoPort: Int, client: PtpIpClient) {
            self.host = host
            self.protoPort = protoPort
            self.client = client
        }
        var guid16: [UInt8] { client.cameraGuid16 }
        var cameraName: String { client.cameraName }
        func close() { client.close() }
    }

    enum PairOutcome {
        case failed, busy, paired
    }

    enum ConnectOutcome {
        case ok, notPaired, busy, failed
    }

    struct FtpEntry: Identifiable, Hashable {
        let name: String
        let path: String
        let isDir: Bool
        let size: Int64
        let timestamp: Int64

        var id: String { path }
        var ext: String {
            let parts = name.split(separator: ".")
            return parts.count >= 2 ? String(parts.last!).lowercased() : ""
        }
    }

    struct DirPage {
        let entries: [FtpEntry]
        let nextOffset: Int
        let hasMore: Bool
    }

    enum PumpResult {
        case completed, failed, cancelled
    }

    final class ObjectTicket {
        let host: String
        let path: String
        let kind: UInt32
        let token: Int64
        let filePort: Int
        let connNo: Int
        let client: PtpIpClient
        init(host: String, path: String, kind: UInt32, token: Int64, filePort: Int, connNo: Int, client: PtpIpClient) {
            self.host = host
            self.path = path
            self.kind = kind
            self.token = token
            self.filePort = filePort
            self.connNo = connNo
            self.client = client
        }
    }

    private var sessions: [String: Session] = [:]
    private let sessionLock = NSLock()
    private var disconnectListeners: [String: () -> Void] = [:]
    private var pairingLink: PtpIpClient?
    private var pairingHost: String?
    private let pairingLock = NSLock()
    private var batchChannel: DataChannel?
    private var batchChannelSession: PtpIpClient?
    private let batchLock = NSLock()

    private init() {}

    // MARK: 生命周期

    func setOnDisconnectedListener(host: String, listener: (() -> Void)?) {
        sessionLock.lock()
        if let l = listener { disconnectListeners[host] = l } else { disconnectListeners.removeValue(forKey: host) }
        sessionLock.unlock()
    }

    private func installDisconnectCallback(host: String, client: PtpIpClient, session: Session) {
        client.onDisconnected = { [weak self] in
            guard let self = self else { return }
            self.sessionLock.lock()
            let current = self.sessions[host]
            let same = current === session && current?.client === client
            if !same {
                self.sessionLock.unlock()
                return
            }
            self.sessions.removeValue(forKey: host)
            let listener = self.disconnectListeners[host]
            self.sessionLock.unlock()
            self.dropBatchChannel()
            listener?()
        }
    }

    func connect(host: String, protoPort: Int, guid16: [UInt8], friendlyName: String,
                 onEvent: ((UInt32, Int, [Int]) -> Void)? = nil) -> ConnectOutcome {
        sessionLock.lock()
        if let s = sessions[host] {
            if s.client.isConnected {
                sessionLock.unlock()
                return .ok
            } else {
                sessions.removeValue(forKey: host)
            }
        }
        sessionLock.unlock()

        return ioQueue.sync {
            let client = PtpIpClient(host: host, protoPort: protoPort, guid16: guid16, friendlyName: friendlyName)
            do {
                try client.connect(timeoutMs: self.connectTimeoutMs)
                if onEvent != nil {
                    try? client.openEventChannel(listener: onEvent!, timeoutMs: self.connectTimeoutMs)
                }
                let session = Session(host: host, protoPort: protoPort, client: client)
                self.sessionLock.lock()
                self.sessions[host] = session
                self.sessionLock.unlock()
                self.installDisconnectCallback(host: host, client: client, session: session)
                return .ok
            } catch PtpError.initFailed(let reason) {
                client.close()
                switch reason {
                case PtpCodec.failNotPaired: return .notPaired
                case PtpCodec.failBusy: return .busy
                default: return .failed
                }
            } catch {
                client.close()
                return .failed
            }
        }
    }

    func sessionOf(_ host: String) -> Session? {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return sessions[host]
    }

    func isConnected(_ host: String) -> Bool {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return sessions[host]?.client.isConnected == true
    }

    // MARK: 配对

    /// 第一步：连上相机并发 PAIR_BEGIN，使相机亮出配对码；连接保持打开。
    func pairBegin(host: String, protoPort: Int, guid16: [UInt8], friendlyName: String) -> PairOutcome {
        pairAbort()
        disconnect(host)
        return ioQueue.sync {
            let client = PtpIpClient(host: host, protoPort: protoPort, guid16: guid16, friendlyName: friendlyName)
            do {
                try client.connectForPairing(timeoutMs: self.pairTimeoutMs)
                let pc = PairingClient(
                    sendReq: { op, tx, blob in
                        try client.sendRaw(PtpCodec.opReqBlob(opCode: op, txId: tx, blob: blob))
                    },
                    recvRsp: { try client.recvPlainOpBlob() }
                )
                _ = try pc.begin(deviceName: friendlyName)
                self.pairingLock.lock()
                self.pairingLink = client
                self.pairingHost = host
                self.pairingLock.unlock()
                return .paired
            } catch is PairingClient.DeviceBusyError {
                client.close()
                return .busy
            } catch {
                client.close()
                return .failed
            }
        }
    }

    /// 第二步：把用户看着相机屏输入的码交给相机核对；成功后这条连接转为正式会话。
    func pairExchange(host: String, code: String, onEvent: ((UInt32, Int, [Int]) -> Void)? = nil) -> PairOutcome {
        pairingLock.lock()
        let client = pairingLink
        let okHost = pairingHost == host
        pairingLock.unlock()
        guard let client = client, okHost else { return .failed }
        return ioQueue.sync {
            do {
                let pc = PairingClient(
                    sendReq: { op, tx, blob in
                        try client.sendRaw(PtpCodec.opReqBlob(opCode: op, txId: tx, blob: blob))
                    },
                    recvRsp: { try client.recvPlainOpBlob() }
                )
                try pc.exchange(code: code)
                self.clearPairingLink(client)
                client.finishPairing(onEvent: onEvent)
                if onEvent != nil {
                    try? client.openEventChannel(listener: onEvent!, timeoutMs: self.connectTimeoutMs)
                }
                let session = Session(host: host, protoPort: client.protoPort, client: client)
                self.sessionLock.lock()
                self.sessions[host] = session
                self.sessionLock.unlock()
                self.installDisconnectCallback(host: host, client: client, session: session)
                return .paired
            } catch {
                client.close()
                self.clearPairingLink(client)
                return .failed
            }
        }
    }

    private func clearPairingLink(_ client: PtpIpClient) {
        pairingLock.lock()
        if pairingLink === client {
            pairingLink = nil
            pairingHost = nil
        }
        pairingLock.unlock()
    }

    /// 放弃进行中的配对连接。
    func pairAbort() {
        pairingLock.lock()
        let client = pairingLink
        pairingLink = nil
        pairingHost = nil
        pairingLock.unlock()
        guard let client = client else { return }
        ioQueue.async {
            let pc = PairingClient(
                sendReq: { op, tx, blob in
                    try client.sendRaw(PtpCodec.opReqBlob(opCode: op, txId: tx, blob: blob))
                },
                recvRsp: { try client.recvPlainOpBlob() }
            )
            pc.abort()
            client.close()
        }
    }

    func disconnect(_ host: String) {
        dropBatchChannel()
        sessionLock.lock()
        let s = sessions.removeValue(forKey: host)
        sessionLock.unlock()
        s?.close()
    }

    func closeAll() {
        sessionLock.lock()
        let all = sessions.values
        sessions.removeAll()
        sessionLock.unlock()
        for s in all { s.close() }
        dropBatchChannel()
    }

    // MARK: 目录浏览 / 元数据

    func listPage(host: String, dir: String, offset: Int, limit: Int = 256,
                  timeoutMs: Int? = nil, reverse: Bool = false) throws -> DirPage {
        let tmo = timeoutMs ?? listTimeoutMs
        return try ioQueue.sync {
            let client = try requireClient(host)
            let json = try client.listDir(path: dir, offset: offset, limit: limit, reverse: reverse, timeoutMs: tmo)
            return try Self.parsePage(String(decoding: json, as: UTF8.self), dir: dir, requestedOffset: offset, requestedLimit: limit)
        }
    }

    func list(host: String, dir: String) throws -> [FtpEntry] {
        try ioQueue.sync {
            let client = try requireClient(host)
            var all: [FtpEntry] = []
            var offset = 0
            while true {
                let json = try client.listDir(path: dir, offset: offset, limit: 256, reverse: false, timeoutMs: ioTimeoutMs)
                let page = try Self.parsePage(String(decoding: json, as: UTF8.self), dir: dir, requestedOffset: offset, requestedLimit: 256)
                all.append(contentsOf: page.entries)
                if !page.hasMore || page.nextOffset <= offset { break }
                offset = page.nextOffset
            }
            return all.sorted { a, b in
                if a.isDir != b.isDir { return a.isDir }
                return a.name.lowercased() < b.name.lowercased()
            }
        }
    }

    func stat(host: String, path: String) throws -> PtpIpClient.StatInfo {
        try ioQueue.sync {
            try requireClient(host).stat(path: path)
        }
    }

    /// 目录计数探针：一次往返拿回“目录现在有多少个条目”（变化检测用）。
    func dirCount(host: String, dir: String) -> Int? {
        do {
            let json = try ioQueue.sync { () -> String in
                let client = try requireClient(host)
                let b = try client.listDir(path: dir, offset: dirCountProbeOffset, limit: 1, reverse: false, timeoutMs: ioTimeoutMs)
                return String(decoding: b, as: UTF8.self)
            }
            if let o = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
               let total = o["nextOffset"] as? Int {
                return total < 0 ? nil : total
            }
            return nil
        } catch {
            return nil
        }
    }

    /// 心跳：一次往返同时拿电量、镜头与 SD 容量（不经 ioQueue 排队，避免被大扫描饿死）。
    func ping(host: String) throws -> PtpIpClient.PingInfo {
        try requireClient(host).ping()
    }

    func deviceInfo(host: String) -> [String: Any]? {
        do {
            let bytes = try ioQueue.sync { () -> [UInt8] in
                try requireClient(host).deviceInfo()
            }
            return try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any]
        } catch {
            return nil
        }
    }

    func pairRemove(host: String) -> Bool {
        do {
            return try ioQueue.sync { try requireClient(host).pairRemove() }
        } catch {
            return false
        }
    }

    func thumbQueue(host: String, op: UInt32, paths: [String]) -> Bool {
        do {
            return try ioQueue.sync { try requireClient(host).thumbQueue(op, paths: paths) }
        } catch {
            return false
        }
    }

    static func parsePage(_ json: String, dir: String, requestedOffset: Int, requestedLimit: Int) throws -> DirPage {
        let text = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return DirPage(entries: [], nextOffset: requestedOffset, hasMore: false) }

        var root: [String: Any]?
        var arr: [[String: Any]] = []
        if text.hasPrefix("[") {
            root = nil
            if let a = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] {
                arr = a
            }
        } else {
            root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            arr = root?["entries"] as? [[String: Any]] ?? []
        }
        var out: [FtpEntry] = []
        for o in arr {
            guard let name = o["name"] as? String, !name.isEmpty,
                  name != ".", name != ".." else { continue }
            out.append(FtpEntry(
                name: name,
                path: joinPath(dir, name),
                isDir: (o["dir"] as? Bool) ?? false,
                size: (o["size"] as? NSNumber)?.int64Value ?? 0,
                timestamp: (o["mtime"] as? NSNumber)?.int64Value ?? 0
            ))
        }
        let sorted = out.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return a.name.lowercased() < b.name.lowercased()
        }
        let hasMore: Bool
        let next: Int
        if let root = root {
            hasMore = (root["hasMore"] as? Bool) ?? false
            next = (root["nextOffset"] as? Int) ?? (requestedOffset + sorted.count)
        } else {
            hasMore = requestedLimit > 0 && sorted.count >= requestedLimit
            next = requestedOffset + sorted.count
        }
        return DirPage(entries: sorted, nextOffset: next, hasMore: hasMore)
    }

    // MARK: 缩略图 / 预览

    /// 大预览（1616×1080 内嵌 JPEG，~0.4MB）。失败返回 nil。
    func fetchVirtualPreview(host: String, cameraPath: String) -> [UInt8]? {
        fetchObject(host: host, path: normalize(cameraPath), kind: PtpCodec.kindPreview, timeoutMs: ioTimeoutMs)
    }

    /// 两步式取图第一步：在控制通道上换取一次性令牌（可在任意线程调用）。
    func openObjectTicket(host: String, cameraPath: String, kind: UInt32) -> ObjectTicket? {
        do {
            let p = normalize(cameraPath)
            let client = try requireClient(host)
            let t = try client.getObjectWhole(path: p, kind: kind)
            return ObjectTicket(host: host, path: p, kind: kind, token: t.token, filePort: t.filePort, connNo: client.connNo, client: client)
        } catch {
            return nil
        }
    }

    /// 两步式取图第二步：开数据连接下载（阻塞，调用方线程）。
    func downloadObject(_ t: ObjectTicket, timeoutMs: Int = 30000) -> [UInt8]? {
        var total: Int64 = -1
        var out = [UInt8]()
        do {
            let received = try DataChannel(host: t.host, filePort: t.filePort, guid16: IdentityStore.shared.guid16, connNo: t.connNo)
                .download(token: t.token, expectedTxId: 1, expectedBytes: -1, timeoutMs: timeoutMs,
                          onTotal: { total = $0 },
                          onChunk: { out.append(contentsOf: $0) })
            // 短收/空占位一律视为失败（绝不把半张图交给上层写进持久缓存）
            if total <= 0 || received != total {
                return nil
            }
            return out
        } catch {
            return nil
        }
    }

    private func fetchObject(host: String, path: String, kind: UInt32, timeoutMs: Int) -> [UInt8]? {
        guard let t = openObjectTicket(host: host, cameraPath: path, kind: kind) else { return nil }
        return downloadObject(t, timeoutMs: timeoutMs)
    }

    // MARK: 批量取件

    /// 批量登记：一个令牌对应一批对象，顺序与 items 一致（≤32 项）。
    func openBatchTicket(host: String, items: [(path: String, kind: UInt32)]) -> ObjectTicket? {
        do {
            let client = try requireClient(host)
            let norm = items.map { (normalize($0.path), $0.kind) }
            let t = try client.getObjectBatch(items: norm)
            return ObjectTicket(host: host, path: "", kind: 0xFFFFFFFF, token: t.token, filePort: t.filePort, connNo: client.connNo, client: client)
        } catch {
            return nil
        }
    }

    func downloadBatch(_ t: ObjectTicket, count: Int, timeoutMs: Int = 30000,
                       labels: [String] = [],
                       refill: (() -> ObjectTicket?)? = nil,
                       onObject: @escaping (Int, [UInt8]?) -> Void) -> Bool {
        if runBatch(t, count: count, timeoutMs: timeoutMs, labels: labels, reuse: true, onObject: onObject) {
            return true
        }
        dropBatchChannel()
        let t2 = refill?() ?? t
        return runBatch(t2, count: count, timeoutMs: timeoutMs, labels: labels, reuse: false, onObject: onObject)
    }

    private func runBatch(_ t: ObjectTicket, count: Int, timeoutMs: Int, labels: [String],
                          reuse: Bool, onObject: @escaping (Int, [UInt8]?) -> Void) -> Bool {
        do {
            let got = try batchChannelFor(t).downloadMany(token: t.token, count: count, timeoutMs: timeoutMs,
                                                          labels: labels, reuse: reuse) { i, b in
                onObject(i, b)
            }
            return got == count
        } catch {
            return false
        }
    }

    private func batchChannelFor(_ t: ObjectTicket) -> DataChannel {
        batchLock.lock()
        defer { batchLock.unlock() }
        if let ch = batchChannel, batchChannelSession === t.client, ch.connNo == t.connNo, !ch.isClosed {
            return ch
        }
        dropBatchChannel()
        let ch = DataChannel(host: t.host, filePort: t.filePort, guid16: IdentityStore.shared.guid16, connNo: t.connNo)
        batchChannel = ch
        batchChannelSession = t.client
        return ch
    }

    private func dropBatchChannel() {
        batchLock.lock()
        batchChannel?.close()
        batchChannel = nil
        batchChannelSession = nil
        batchLock.unlock()
    }

    // MARK: 下载（偏移起点 → 断点续传）

    /// 从 startOffset 续传下载到 out（cancelled 每块检查）。
    /// - 收满 → completed；中途取消 → cancelled（已写字节保留，可带同一 offset 续传）；其余 → failed
    func pumpToStream(host: String, path: String, startOffset: Int64, out: FileHandle,
                      cancelled: @escaping () -> Bool,
                      onProgress: @escaping (Int64) -> Void) -> PumpResult {
        do {
            var total: Int64 = -1
            let result = try xferQueue.sync { () -> PumpResult in
                let client = try requireClient(host)
                let st = try client.stat(path: path)
                if startOffset > st.size {
                    throw PtpError.protocolError("续传位置超过对象大小")
                }
                let ticket = try client.getObject(path: path, kind: PtpCodec.kindOriginal, offset: startOffset, length: -1)
                let expectedRemaining = st.size - startOffset

                var written = startOffset
                var lastReported = written
                var lastTick = Date(timeIntervalSince1970: 0)

                func report(_ now: Int64) {
                    if now - lastReported < 512 * 1024 && Date().timeIntervalSince(lastTick) < 0.12 {
                        return
                    }
                    lastReported = now
                    lastTick = Date()
                    onProgress(now)
                }

                var received: Int64 = 0
                let ch = DataChannel(host: host, filePort: ticket.filePort, guid16: IdentityStore.shared.guid16, connNo: client.connNo)
                received = try ch.download(
                    token: ticket.token, expectedTxId: 1, expectedBytes: expectedRemaining,
                    timeoutMs: ioTimeoutMs,
                    onTotal: { total = $0 },
                    cancelled: cancelled,
                    onChunk: { chunk in
                        try out.write(contentsOf: chunk)
                        written += Int64(chunk.count)
                        report(written)
                    }
                )
                onProgress(written)

                if cancelled() {
                    return .cancelled
                }
                if total >= 0 && received == total {
                    return .completed
                }
                return .failed
            }
            return result
        } catch {
            return cancelled() ? .cancelled : .failed
        }
    }

    // MARK: 内部

    private func requireClient(_ host: String) throws -> PtpIpClient {
        sessionLock.lock()
        let s = sessions[host]
        sessionLock.unlock()
        guard let s = s else { throw PtpError.protocolError("未连接相机 \(host)") }
        if !s.client.isConnected {
            disconnect(host)
            throw PtpError.protocolError("相机连接已断开 \(host)")
        }
        return s.client
    }

    private func normalize(_ p: String) -> String {
        p.hasPrefix("/") ? p : "/" + p
    }

    // MARK: 路径小件

    static func joinPath(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    static func parentOf(_ path: String) -> String {
        let p = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let idx = p.lastIndex(of: "/") else { return "/" }
        if idx == p.startIndex { return "/" }
        return String(p[..<idx])
    }

    static func breadcrumbOf(_ path: String) -> [(String, String)] {
        var out: [(String, String)] = [("根", "/")]
        var acc = ""
        for seg in path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/") where !seg.isEmpty {
            acc += "/" + seg
            out.append((String(seg), acc))
        }
        return out
    }
}
