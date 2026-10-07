import Foundation

/// PTP/IP 控制连接客户端（手机端）—— 镜像安卓端 `PtpIpClient.kt`。
///
/// 一次 connect() 完成：
/// 1. TCP 连协议端口 → 发 Init Command Request → 收 Init Command Ack / Init Fail
/// 2. 起读线程收发操作请求/响应（request 同步等响应）
///
/// 全程明文（与安卓端一致，加密层已移除）。事件连接是同一协议端口上的第二条 TCP。
final class PtpIpClient {

    /// 配对阶段固定事务号（与相机端一致）。
    static let txBegin = 0x41
    static let txExchange = 0x42
    static let txAbort = 0x44

    /// 协议代次：主版本<<16 | 次版本<<8 | 修订号。1.0 = (1 << 16) | 0。
    static let protoVersion = (1 << 16) | 0

    static func formatProtoVersion(_ v: Int) -> String {
        let major = (v >> 16) & 0xFF
        let minor = (v >> 8) & 0xFF
        let rev = v & 0xFF
        return rev == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(rev)"
    }

    struct PingInfo {
        let batteryPct: Int
        let lens: String
        let sdTotal: Int64
        let sdUsed: Int64
    }

    struct StatInfo {
        let size: Int64
        let mtime: Int64
    }

    struct TransferTicket {
        let token: Int64
        let filePort: Int
    }

    let host: String
    let protoPort: Int
    private let guid16: [UInt8]
    private let friendlyName: String

    private(set) var cameraGuid16: [UInt8] = [UInt8](repeating: 0, count: 16)
    private(set) var cameraName: String = ""
    private(set) var protoVersion: Int = 0
    private(set) var connNo: Int = 0

    private var control: TCPStream?
    private var event: TCPStream?
    private let txCounter = LockedCounter()
    private var pending: [Int: PendingOp] = [:]
    private let pendingLock = NSLock()
    private var closed = false
    private let closeLock = NSLock()
    var onDisconnected: (() -> Void)?
    var eventListener: ((UInt32, Int, [Int]) -> Void)?

    init(host: String, protoPort: Int, guid16: [UInt8], friendlyName: String) {
        self.host = host
        self.protoPort = protoPort
        self.guid16 = guid16
        self.friendlyName = friendlyName
    }

    var isConnected: Bool {
        closeLock.lock(); defer { closeLock.unlock() }
        return !closed && control?.isAlive == true
    }

    // MARK: 连接与认证

    /// 已配对相机的常规连接：Init Cmd → 直接进控制循环。
    func connect(timeoutMs: Int = 8000) throws {
        let link = try openLink(timeoutMs: timeoutMs)
        try withHandshakeTimeout(link, timeoutMs) { try self.initHandshake(link) }
        link.startReader(onDisconnected: { [weak self] in self?.notifyControlDisconnected() }) { [weak self] m in
            self?.onControlMessage(m)
        }
    }

    /// 配对第一步：Init 握手，但不起控制读线程——配对期还要手工收发 PAIR_BEGIN/PAIR_EXCHANGE。
    func connectForPairing(timeoutMs: Int = 20000) throws {
        let link = try openLink(timeoutMs: timeoutMs)
        try withHandshakeTimeout(link, timeoutMs) { try self.initHandshake(link) }
    }

    func sendRaw(_ framed: [UInt8]) throws {
        guard let link = control else { throw PtpError.protocolError("配对连接已关闭") }
        try link.write(framed)
    }

    func recvPlainOpBlob() throws -> PtpCodec.OpBlob {
        guard let link = control else { throw PtpError.protocolError("配对连接已关闭") }
        guard let m = try PtpCodec.read(link) else { throw PtpError.protocolError("配对阶段连接被关闭") }
        if PtpCodec.i32(m.body, 0) == Int(PtpCodec.dpDataIn) {
            return try PtpCodec.parseOpBlob(m.body)
        }
        let o = try PtpCodec.parseOp(m.body)
        var out = PtpCodec.OpBlob()
        out.dataPhase = o.dataPhase
        out.code = o.code
        out.txId = o.txId
        out.params = o.params
        return out
    }

    /// 配对成功：这条连接转为正式会话。
    func finishPairing(onEvent: ((UInt32, Int, [Int]) -> Void)? = nil) {
        guard let link = control else { return }
        eventListener = onEvent
        link.startReader(onDisconnected: { [weak self] in self?.notifyControlDisconnected() }) { [weak self] m in
            self?.onControlMessage(m)
        }
    }

    private func openLink(timeoutMs: Int) throws -> TCPStream {
        let link = try TCPStream.connect(host: host, port: protoPort, timeoutMs: timeoutMs)
        control = link
        return link
    }

    private func withHandshakeTimeout(_ link: TCPStream, _ ms: Int, body: () throws -> Void) rethrows {
        link.setReceiveTimeout(ms)
        defer { link.setReceiveTimeout(0) }
        try body()
    }

    private func initHandshake(_ link: TCPStream) throws {
        try link.write(PtpCodec.initCmdReq(guid: guid16, friendlyName: friendlyName, protoVer: Self.protoVersion))
        guard let first = try PtpCodec.read(link) else {
            throw PtpError.protocolError("相机在握手前关闭连接")
        }
        if first.type == PtpCodec.tInitFail {
            let reason = first.body.count >= 4 ? UInt32(PtpCodec.i32(first.body, 0)) : 0xFFFFFFFF
            link.closeQuietly()
            throw PtpError.initFailed(reason: reason)
        }
        guard first.type == PtpCodec.tInitCmdAck else {
            link.closeQuietly()
            throw PtpError.protocolError("期望 Init Command Ack，收到 type=0x\(String(format: "%04X", first.type))")
        }
        guard first.body.count >= 21 else {
            link.closeQuietly()
            throw PtpError.protocolError("Init Command Ack 过短")
        }
        connNo = PtpCodec.i32(first.body, 0)
        cameraGuid16 = Array(first.body[4..<20])
        let (nm, next) = PtpCodec.readName(first.body, 20)
        cameraName = nm
        protoVersion = next + 4 <= first.body.count ? PtpCodec.i32(first.body, next) : 0
    }

    // MARK: 事件连接

    func openEventChannel(listener: @escaping (UInt32, Int, [Int]) -> Void, timeoutMs: Int = 8000) throws {
        eventListener = listener
        let socket = try TCPStream.connect(host: host, port: protoPort, timeoutMs: timeoutMs)
        event = socket
        try socket.write(PtpCodec.initEventReq(connNo: connNo))
        guard let ack = try PtpCodec.read(socket) else {
            throw PtpError.protocolError("事件连接：相机未回 Init Event Ack")
        }
        guard ack.type == PtpCodec.tInitEventAck else {
            socket.closeQuietly()
            throw PtpError.protocolError("事件连接：期望 Init Event Ack，收到 type=0x\(String(format: "%04X", ack.type))")
        }
        socket.startReader { m in
            guard m.type == PtpCodec.tEvent else { return }
            if let ev = try? PtpCodec.parseEvent(m.body) {
                self.eventListener?(ev.code, ev.txId, ev.params)
            }
        }
    }

    // MARK: 控制读线程消息分发

    private func onControlMessage(_ m: PtpCodec.Msg) {
        switch m.type {
        case PtpCodec.tOperationRsp:
            guard let res = try? Self.parseResponse(m.body) else { return }
            pendingLock.lock()
            let op = pending.removeValue(forKey: res.txId)
            pendingLock.unlock()
            op?.deliver(res.code, res.params, res.blob)
        case PtpCodec.tEvent:
            if let ev = try? PtpCodec.parseEvent(m.body) {
                eventListener?(ev.code, ev.txId, ev.params)
            }
        default:
            break
        }
    }

    private struct OpResult {
        let code: UInt32
        let txId: Int
        let params: [Int]
        let blob: [UInt8]
    }

    private static func parseResponse(_ plain: [UInt8]) throws -> OpResult {
        if plain.count >= 4 && PtpCodec.i32(plain, 0) == Int(PtpCodec.dpDataIn) {
            let b = try PtpCodec.parseOpBlob(plain)
            return OpResult(code: b.code, txId: b.txId, params: b.params, blob: b.blob)
        }
        let o = try PtpCodec.parseOp(plain)
        return OpResult(code: o.code, txId: o.txId, params: o.params, blob: [])
    }

    private final class PendingOp {
        let sem = DispatchSemaphore(value: 0)
        var code: UInt32 = 0
        var params: [Int] = []
        var blob: [UInt8] = []
        func deliver(_ c: UInt32, _ p: [Int], _ b: [UInt8]) {
            code = c; params = p; blob = b
            sem.signal()
        }
    }

    /// 发一个操作请求并等响应（同步阻塞）。
    private func request(_ frame: [UInt8], timeoutMs: Int = 8000) throws -> OpResult {
        guard let link = control else { throw PtpError.protocolError("控制连接未建立") }
        let txId = PtpCodec.i32(frame, PtpCodec.headerLen + 6)
        let op = PendingOp()
        pendingLock.lock()
        pending[txId] = op
        pendingLock.unlock()
        defer {
            pendingLock.lock()
            pending.removeValue(forKey: txId)
            pendingLock.unlock()
        }
        try link.write(frame)
        if op.sem.wait(timeout: .now() + .milliseconds(timeoutMs)) == .success {
            return OpResult(code: op.code, txId: txId, params: op.params, blob: op.blob)
        }
        throw PtpError.timeout("操作超时（tx=\(txId)）")
    }

    private func nextTx() -> Int { txCounter.increment() }

    private func pathBytes(_ path: String) -> [UInt8] { Array(path.utf8) }

    // MARK: 具体操作

    func ping() throws -> PingInfo {
        let tx = nextTx()
        let r = try request(PtpCodec.opReq(dataPhase: PtpCodec.dpNone, opCode: PtpCodec.opPing, txId: tx, params: nil))
        try checkOk(r)
        let bat = r.params.first ?? -1
        let raw = String(decoding: r.blob, as: UTF8.self)
        var lens = ""
        var sdT: Int64 = -1
        var sdU: Int64 = -1
        if let o = try? JSONSerialization.jsonObject(with: Data(r.blob)) as? [String: Any] {
            lens = o["lens"] as? String ?? ""
            sdT = o["sdT"] as? Int64 ?? -1
            sdU = o["sdU"] as? Int64 ?? -1
        }
        return PingInfo(batteryPct: bat, lens: lens, sdTotal: sdT, sdUsed: sdU)
    }

    func pairRemove() -> Bool {
        let tx = nextTx()
        guard let r = try? request(PtpCodec.opReq(dataPhase: PtpCodec.dpNone, opCode: PtpCodec.opPairRemove, txId: tx, params: nil)) else {
            return false
        }
        return r.code == PtpCodec.rcOk
    }

    func deviceInfo() throws -> [UInt8] {
        let tx = nextTx()
        let r = try request(PtpCodec.opReq(dataPhase: PtpCodec.dpNone, opCode: PtpCodec.opDeviceInfo, txId: tx, params: nil))
        try checkOk(r)
        return r.blob
    }

    func listDir(path: String, offset: Int = 0, limit: Int = 0, reverse: Bool = false, timeoutMs: Int = 8000) throws -> [UInt8] {
        let tx = nextTx()
        let r = try request(
            PtpCodec.opReqBlobParams(opCode: PtpCodec.opListDir, txId: tx,
                                     params: [offset, limit, reverse ? 1 : 0], blob: pathBytes(path)),
            timeoutMs: timeoutMs
        )
        try checkOk(r)
        return r.blob
    }

    func stat(path: String) throws -> StatInfo {
        let tx = nextTx()
        let r = try request(PtpCodec.opReqBlob(opCode: PtpCodec.opStat, txId: tx, blob: pathBytes(path)))
        try checkOk(r)
        guard r.params.count >= 4 else { throw PtpError.protocolError("STAT 参数不足") }
        let size = (Int64(r.params[0]) & 0xFFFF_FFFF) | ((Int64(r.params[1]) & 0xFFFF_FFFF) << 32)
        let mtime = (Int64(r.params[2]) & 0xFFFF_FFFF) | ((Int64(r.params[3]) & 0xFFFF_FFFF) << 32)
        return StatInfo(size: size, mtime: mtime)
    }

    /// 登记一次性传输凭据，随后用 DataChannel 走文件端口取数据。
    func getObject(path: String, kind: UInt32, offset: Int64, length: Int) throws -> TransferTicket {
        let tx = nextTx()
        let params: [Int] = [
            Int(kind),
            Int(truncatingIfNeeded: offset & 0xFFFF_FFFF),
            Int(truncatingIfNeeded: (offset >> 32) & 0xFFFF_FFFF),
            length,
        ]
        let r = try request(PtpCodec.opReqBlobParams(opCode: PtpCodec.opGetObject, txId: tx, params: params, blob: pathBytes(path)))
        try checkOk(r)
        guard r.params.count >= 2 else { throw PtpError.protocolError("GET_OBJECT 参数不足") }
        let token = Int64(truncatingIfNeeded: UInt64(UInt32(bitPattern: Int32(r.params[0]))))
        return TransferTicket(token: token, filePort: r.params[1])
    }

    func getObjectWhole(path: String, kind: UInt32) throws -> TransferTicket {
        try getObject(path: path, kind: kind, offset: 0, length: -1)
    }

    /// 批量登记：blob 每行 "T\t/path"（小图）或 "P\t/path"（大预览），≤32 项。
    func getObjectBatch(items: [(path: String, kind: UInt32)]) throws -> TransferTicket {
        let tx = nextTx()
        var sb = ""
        for item in items {
            sb.append(item.kind == PtpCodec.kindPreview ? "P\t" : "T\t")
            sb.append(item.path)
            sb.append("\n")
        }
        let r = try request(PtpCodec.opReqBlob(opCode: PtpCodec.opGetObjectBatch, txId: tx, blob: pathBytes(sb)))
        try checkOk(r)
        guard r.params.count >= 2 else { throw PtpError.protocolError("GET_OBJECT_BATCH 参数不足") }
        let token = Int64(truncatingIfNeeded: UInt64(UInt32(bitPattern: Int32(r.params[0]))))
        return TransferTicket(token: token, filePort: r.params[1])
    }

    /// 缩略图队列控制（begin/pause/resume/cancel），paths 按行拼成一个 blob。
    func thumbQueue(_ op: UInt32, paths: [String]) -> Bool {
        let tx = nextTx()
        let text = paths.joined(separator: "\n")
        guard let r = try? request(PtpCodec.opReqBlob(opCode: op, txId: tx, blob: pathBytes(text))) else {
            return false
        }
        return r.code == PtpCodec.rcOk
    }

    private func checkOk(_ r: OpResult) throws {
        if r.code != PtpCodec.rcOk {
            throw PtpError.protocolError("相机回错误码 0x\(String(format: "%04X", r.code))")
        }
    }

    // MARK: 关闭

    private func notifyControlDisconnected() {
        closeLock.lock(); let c = closed; closeLock.unlock()
        if c { return }
        onDisconnected?()
    }

    func close() {
        closeLock.lock()
        if closed { closeLock.unlock(); return }
        closed = true
        closeLock.unlock()
        event?.closeQuietly()
        control?.closeQuietly()
        event = nil
        control = nil
        pendingLock.lock()
        let ops = pending.values
        pending.removeAll()
        pendingLock.unlock()
        for op in ops {
            op.deliver(0xFFFF, [], [])   // 唤醒挂起事务
        }
        eventListener = nil
    }
}

/// 线程安全计数器。
final class LockedCounter {
    private var value = 0
    private let lock = NSLock()
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}
