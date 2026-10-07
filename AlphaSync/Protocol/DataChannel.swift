import Foundation

/// 数据通道（文件端口）—— 镜像安卓端 `DataChannel.kt`。
///
/// 时序（全程明文）：
/// ```
/// 我 ── DATA_OPEN{GUID(16), ConnNo(4), token(8)} ──▶ 相机（文件端口）
/// 我 ◀── DATA_OPEN_ACK ───────────────────────── 相机
/// 我 ◀── Start Data{tx=1, total(8)} ───────────── 相机 ┐
/// 我 ◀── Data{tx=1, chunk}* ──────────────────── 相机 ├ 明文帧
/// 我 ◀── End Data{tx=1, 末块} ────────────────── 相机 ┘
/// ```
/// 取消语义：由本端断开 socket 表达。
final class DataChannel {

    private let host: String
    private let filePort: Int
    private let guid16: [UInt8]
    let connNo: Int
    private var stream: TCPStream?
    private var closed = false
    private let lock = NSLock()

    init(host: String, filePort: Int, guid16: [UInt8], connNo: Int) {
        self.host = host
        self.filePort = filePort
        self.guid16 = guid16
        self.connNo = connNo
    }

    var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed || stream?.isAlive != true
    }

    /// 拉取一个对象。
    /// - Parameters:
    ///   - onTotal: 收到 Start Data 时回调对象总长
    ///   - cancelled: 轮询式取消检查
    ///   - onChunk: 每收到一块回调 (字节数组)——必须在本回调里用掉，不要留引用
    /// - Returns: 实际收到的字节数
    @discardableResult
    func download(token: Int64, expectedTxId: Int = 1, expectedBytes: Int64 = -1,
                  timeoutMs: Int = 8000,
                  onTotal: ((Int64) -> Void)? = nil,
                  cancelled: () -> Bool = { false },
                  onChunk: @escaping ([UInt8]) throws -> Void) throws -> Int64 {
        let s = try TCPStream.connect(host: host, port: filePort, timeoutMs: timeoutMs)
        lock.lock(); stream = s; lock.unlock()
        s.setReceiveTimeout(timeoutMs)

        defer { close() }

        // ① DATA_OPEN（明文）
        try s.write(PtpCodec.dataOpen(guid: guid16, connNo: connNo, token: token))
        guard let ack = try PtpCodec.read(s) else {
            throw PtpError.protocolError("文件端口未回 DATA_OPEN_ACK")
        }
        guard ack.type == PtpCodec.tDataOpenAck else {
            throw PtpError.protocolError("文件端口期望 DATA_OPEN_ACK，收到 type=0x\(String(format: "%04X", ack.type))")
        }

        // ② 收数据帧（明文）
        var received: Int64 = 0
        var total: Int64 = -1
        var sawStart = false
        var sawEnd = false

        while !closed && !cancelled() {
            guard let m = try PtpCodec.read(s) else { break }
            switch m.type {
            case PtpCodec.tStartData:
                if sawStart { throw PtpError.protocolError("重复 START_DATA") }
                if PtpCodec.txIdOf(m.body) != expectedTxId {
                    throw PtpError.protocolError("START_DATA txId 不匹配")
                }
                total = try PtpCodec.totalOf(m.body)
                if total < 0 || (expectedBytes >= 0 && total != expectedBytes) {
                    throw PtpError.protocolError("START_DATA total=\(total)，期望 \(expectedBytes)")
                }
                sawStart = true
                onTotal?(total)
            case PtpCodec.tData:
                if !sawStart { throw PtpError.protocolError("未收到 START_DATA") }
                if PtpCodec.txIdOf(m.body) != expectedTxId {
                    throw PtpError.protocolError("DATA txId 不匹配")
                }
                let n = dataLen(m.body)
                if n > 0 {
                    try onChunk(Array(m.body[4..<m.body.count]))
                    received += Int64(n)
                    if total >= 0 && received > total {
                        throw PtpError.protocolError("接收字节超过 total")
                    }
                }
            case PtpCodec.tEndData:
                if !sawStart { throw PtpError.protocolError("END_DATA 前未收到 START_DATA") }
                if PtpCodec.txIdOf(m.body) != expectedTxId {
                    throw PtpError.protocolError("END_DATA txId 不匹配")
                }
                let n = dataLen(m.body)
                if n > 0 {
                    try onChunk(Array(m.body[4..<m.body.count]))
                    received += Int64(n)
                }
                if total < 0 || received != total {
                    throw PtpError.protocolError("END_DATA 长度不匹配：\(received)/\(total)")
                }
                sawEnd = true
                return received
            case PtpCodec.tCancel:
                return received
            default:
                throw PtpError.protocolError("数据通道收到意外包 type=0x\(String(format: "%04X", m.type))")
            }
        }
        if !cancelled() && (!sawStart || !sawEnd) {
            throw PtpError.protocolError("数据通道未完整结束")
        }
        return received
    }

    /// 批量收件：一次 DATA_OPEN 之后，按 txId = 第几项（1 起）连续收 count 项。
    /// 空对象（total=0）= 相机端标记“该项不可用”，回调 nil。
    func downloadMany(token: Int64, count: Int, timeoutMs: Int = 8000,
                       labels: [String] = [],
                       reuse: Bool = false,
                       onObject: @escaping (Int, [UInt8]?) -> Void) throws -> Int {
        let existing: TCPStream? = {
            lock.lock(); defer { lock.unlock() }
            return stream
        }()
        let s: TCPStream
        if reuse, let e = existing, e.isAlive {
            s = e
            s.setReceiveTimeout(timeoutMs)
        } else {
            s = try TCPStream.connect(host: host, port: filePort, timeoutMs: timeoutMs)
            lock.lock(); stream = s; lock.unlock()
            s.setReceiveTimeout(timeoutMs)
        }

        var done = 0
        defer {
            // 复用模式只在整批完整收完时才留下连接；中途退出时自保关闭
            if !reuse || done < count { close() }
        }

        // ① DATA_OPEN
        try s.write(PtpCodec.dataOpen(guid: guid16, connNo: connNo, token: token))
        guard let ack = try PtpCodec.read(s) else {
            throw PtpError.protocolError("文件端口未回 DATA_OPEN_ACK")
        }
        guard ack.type == PtpCodec.tDataOpenAck else {
            throw PtpError.protocolError("批量通道期望 DATA_OPEN_ACK，收到 type=0x\(String(format: "%04X", ack.type))")
        }

        // ② 逐项收
        while !closed && done < count {
            guard let m = try PtpCodec.read(s) else { break }
            if m.type != PtpCodec.tStartData {
                throw PtpError.protocolError("批量通道期望 START_DATA，收到 type=0x\(String(format: "%04X", m.type))")
            }
            let tx = PtpCodec.txIdOf(m.body)
            let total = try PtpCodec.totalOf(m.body)
            var out = [UInt8]()
            var got: Int64 = 0
            var ended = false
            while !closed {
                guard let f = try PtpCodec.read(s) else { break }
                let n = dataLen(f.body)
                switch f.type {
                case PtpCodec.tData:
                    if PtpCodec.txIdOf(f.body) != tx {
                        throw PtpError.protocolError("批量 DATA txId 不匹配")
                    }
                    if n > 0 {
                        out.append(contentsOf: f.body[4..<f.body.count])
                        got += Int64(n)
                    }
                case PtpCodec.tEndData:
                    if PtpCodec.txIdOf(f.body) != tx {
                        throw PtpError.protocolError("批量 END_DATA txId 不匹配")
                    }
                    if n > 0 {
                        out.append(contentsOf: f.body[4..<f.body.count])
                        got += Int64(n)
                    }
                    ended = true
                    break
                default:
                    throw PtpError.protocolError("批量通道收到意外包 type=0x\(String(format: "%04X", f.type))")
                }
            }
            if !ended { return done }
            // 长度不符（短收）或 total==0（不可用占位）→ 回调 nil
            let arr: [UInt8]? = (total > 0 && got == total) ? out : nil
            onObject(tx - 1, arr)
            done += 1
        }
        return done
    }

    private func dataLen(_ body: [UInt8]) -> Int {
        body.count <= 4 ? 0 : body.count - 4
    }

    func close() {
        lock.lock(); closed = true; let s = stream; stream = nil; lock.unlock()
        s?.closeQuietly()
    }
}
