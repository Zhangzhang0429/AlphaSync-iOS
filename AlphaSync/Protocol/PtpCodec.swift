import Foundation

/// PTP/IP（CIPA DC-X005 + AlphaSync 厂商扩展）线格式编解码。
/// 与安卓端 `PtpCodec.kt` 逐字节一致：所有多字节整数一律小端（LE）。
enum PtpCodec {

    // MARK: 通用包头
    static let headerLen = 8
    static let maxPacket = 1024 * 1024
    static let chunk = 128 * 1024

    // MARK: 包类型（标准区 0x01–0x0E）
    static let tInitCmdReq: UInt32 = 0x0001
    static let tInitCmdAck: UInt32 = 0x0002
    static let tInitEventReq: UInt32 = 0x0003
    static let tInitEventAck: UInt32 = 0x0004
    static let tInitFail: UInt32 = 0x0005
    static let tOperationReq: UInt32 = 0x0006
    static let tOperationRsp: UInt32 = 0x0007
    static let tEvent: UInt32 = 0x0008
    static let tStartData: UInt32 = 0x0009
    static let tData: UInt32 = 0x000A
    static let tEndData: UInt32 = 0x000B
    static let tCancel: UInt32 = 0x000C
    static let tProbeReq: UInt32 = 0x000D
    static let tProbeResp: UInt32 = 0x000E

    // MARK: 厂商扩展包类型
    static let tDataOpen: UInt32 = 0x0040
    static let tDataOpenAck: UInt32 = 0x0041

    // MARK: 数据阶段
    static let dpNone: UInt32 = 0
    static let dpDataIn: UInt32 = 1
    static let dpDataOut: UInt32 = 2

    // MARK: Init Fail 原因
    static let failRejected: UInt32 = 0x01
    static let failUnsupported: UInt32 = 0x02
    static let failBusy: UInt32 = 0x03
    static let failNotPaired: UInt32 = 0x04

    // MARK: 厂商操作码
    static let opPairBegin: UInt32 = 0x9001
    static let opPairExchange: UInt32 = 0x9002
    static let opPairAbort: UInt32 = 0x9004
    static let opPairRemove: UInt32 = 0x9005
    static let opPing: UInt32 = 0x9012
    static let opDeviceInfo: UInt32 = 0x9013
    static let opListDir: UInt32 = 0x9020
    static let opStat: UInt32 = 0x9021
    static let opGetObject: UInt32 = 0x9022
    static let opThumbQueueBegin: UInt32 = 0x9023
    static let opThumbQueuePause: UInt32 = 0x9024
    static let opThumbQueueResume: UInt32 = 0x9025
    static let opThumbQueueCancel: UInt32 = 0x9026
    static let opGetObjectBatch: UInt32 = 0x9027

    // MARK: 厂商事件码
    static let evThumbProgress: UInt32 = 0x9041
    static let evPairedRemoved: UInt32 = 0x9042
    static let evAppExiting: UInt32 = 0x9043
    static let evModeSwitching: UInt32 = 0x9044
    static let evDisconnecting: UInt32 = 0x9045
    static let evEnteringBackground: UInt32 = 0x9046

    static let discReasonPairing: UInt32 = 0
    static let discReasonError: UInt32 = 1
    static let discReasonOther: UInt32 = 2

    static let modeCodeWifi: UInt32 = 0
    static let modeCodeHotspot: UInt32 = 1

    // MARK: 响应码
    static let rcOk: UInt32 = 0x2001
    static let rcGeneralError: UInt32 = 0x2002
    static let rcSessionNotOpen: UInt32 = 0x2003
    static let rcInvalidTx: UInt32 = 0x2004
    static let rcNotSupported: UInt32 = 0x2005
    static let rcAccessDenied: UInt32 = 0x2006
    static let rcNotFound: UInt32 = 0x2007
    static let rcDeviceBusy: UInt32 = 0x2008
    static let rcPairingFailed: UInt32 = 0x2009
    static let rcCanceled: UInt32 = 0x200B

    // MARK: GET_OBJECT kind
    static let kindThumb: UInt32 = 0
    static let kindPreview: UInt32 = 1
    static let kindOriginal: UInt32 = 2

    /// 厂商标记：探测包靠它区分“这是不是 AlphaSync”（协议契约，与相机端逐字一致）。
    static let vendorTag = "AlphaSync/1.0"

    // MARK: 基础字节读写（小端）

    static func u8(_ b: [UInt8], _ off: Int) -> UInt8 { b[off] }

    static func u16(_ b: [UInt8], _ off: Int) -> Int {
        Int(b[off]) | (Int(b[off + 1]) << 8)
    }

    static func i32(_ b: [UInt8], _ off: Int) -> Int {
        Int(b[off]) | (Int(b[off + 1]) << 8) | (Int(b[off + 2]) << 16) | (Int(b[off + 3]) << 24)
    }

    static func i64(_ b: [UInt8], _ off: Int) -> Int64 {
        let lo = Int64(bitPattern: UInt64(bitPattern: Int64(i32(b, off))) & 0xFFFF_FFFF)
        let hi = Int64(bitPattern: UInt64(bitPattern: Int64(i32(b, off + 4))) & 0xFFFF_FFFF)
        return lo | (hi << 32)
    }

    static func put16(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        b[off] = UInt8(v & 0xFF)
        b[off + 1] = UInt8((v >> 8) & 0xFF)
    }

    static func put32(_ b: inout [UInt8], _ off: Int, _ v: Int) {
        b[off] = UInt8(v & 0xFF)
        b[off + 1] = UInt8((v >> 8) & 0xFF)
        b[off + 2] = UInt8((v >> 16) & 0xFF)
        b[off + 3] = UInt8((v >> 24) & 0xFF)
    }

    static func put32u(_ b: inout [UInt8], _ off: Int, _ v: UInt32) {
        put32(&b, off, Int(bitPattern: v))
    }

    static func put64(_ b: inout [UInt8], _ off: Int, _ v: Int64) {
        put32(&b, off, Int(truncatingIfNeeded: v & 0xFFFF_FFFF))
        put32(&b, off + 4, Int(truncatingIfNeeded: (v >> 32) & 0xFFFF_FFFF))
    }

    // MARK: 组帧 / 解帧

    static func header(type: UInt32, payloadLen: Int) -> [UInt8] {
        var h = [UInt8](repeating: 0, count: headerLen)
        put32(&h, 0, headerLen + payloadLen)
        put32u(&h, 4, type)
        return h
    }

    static func frame(_ type: UInt32, _ payload: [UInt8]?) -> [UInt8] {
        let n = payload?.count ?? 0
        var out = [UInt8](repeating: 0, count: headerLen + n)
        put32(&out, 0, out.count)
        put32u(&out, 4, type)
        if n > 0, let p = payload {
            out.replaceSubrange(headerLen..<out.count, with: p)
        }
        return out
    }

    struct Msg {
        let type: UInt32
        let body: [UInt8]
    }

    /// 从字节流读一个完整包；返回 nil 表示对端干净关闭，截断/坏长度抛错。
    static func read(_ input: InputStreamLike) throws -> Msg? {
        guard let h = try input.readFully(headerLen) else { return nil }
        let len = i32(h, 0)
        let type = UInt32(bitPattern: UInt32(i32(h, 4)))
        if len < headerLen || len > maxPacket {
            throw PtpError.badFrame("坏包长度: \(len) (type=0x\(String(format: "%04X", type)))")
        }
        var body = [UInt8]()
        if len > headerLen {
            guard let b = try input.readFully(len - headerLen) else {
                throw PtpError.badFrame("包体截断")
            }
            body = b
        }
        return Msg(type: type, body: body)
    }

    // MARK: FriendlyName：1 字节字符数 + UTF-16LE

    static func nameLen(_ s: String) -> Int { 1 + s.utf16.count * 2 }

    static func writeName(_ buf: inout [UInt8], _ off: Int, _ s: String) -> Int {
        let chars = s.utf16.prefix(255)
        buf[off] = UInt8(chars.count)
        var i = 0
        for c in chars {
            let v = Int(c)
            buf[off + 1 + i * 2] = UInt8(v & 0xFF)
            buf[off + 1 + i * 2 + 1] = UInt8((v >> 8) & 0xFF)
            i += 1
        }
        return 1 + chars.count * 2
    }

    /// 读 name，返回 (字符串, 下一偏移)。
    static func readName(_ b: [UInt8], _ off: Int) -> (String, Int) {
        let chars = Int(b[off])
        var scalar = [UInt16]()
        scalar.reserveCapacity(chars)
        for i in 0..<chars {
            let lo = UInt16(b[off + 1 + i * 2])
            let hi = UInt16(b[off + 1 + i * 2 + 1])
            scalar.append(hi << 8 | lo)
        }
        let s = String(utf16CodeUnits: scalar, count: scalar.count)
        return (s, off + 1 + chars * 2)
    }

    // MARK: 各类包构造器

    static func initCmdReq(guid: [UInt8], friendlyName: String, protoVer: Int) -> [UInt8] {
        let nl = nameLen(friendlyName)
        var p = [UInt8](repeating: 0, count: 16 + nl + 4)
        p.replaceSubrange(0..<16, with: guid)
        _ = writeName(&p, 16, friendlyName)
        put32(&p, 16 + nl, protoVer)
        return frame(tInitCmdReq, p)
    }

    static func initCmdAck(connNo: Int, guid: [UInt8], friendlyName: String, protoVer: Int) -> [UInt8] {
        let nl = nameLen(friendlyName)
        var p = [UInt8](repeating: 0, count: 4 + 16 + nl + 4)
        put32(&p, 0, connNo)
        p.replaceSubrange(4..<20, with: guid)
        _ = writeName(&p, 20, friendlyName)
        put32(&p, 20 + nl, protoVer)
        return frame(tInitCmdAck, p)
    }

    static func initEventReq(connNo: Int) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 4)
        put32(&p, 0, connNo)
        return frame(tInitEventReq, p)
    }

    static func initEventAck() -> [UInt8] { frame(tInitEventAck, []) }

    static func initFail(_ reason: UInt32) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 4)
        put32u(&p, 0, reason)
        return frame(tInitFail, p)
    }

    /// 标准 Operation Request / Response。
    static func opBody(dataPhase: UInt32, code: UInt32, txId: Int, params: [Int]?) -> [UInt8] {
        let n = params?.count ?? 0
        var p = [UInt8](repeating: 0, count: 10 + n * 4)
        put32u(&p, 0, dataPhase)
        put16(&p, 4, Int(code & 0xFFFF))
        put32(&p, 6, txId)
        for i in 0..<n {
            put32(&p, 10 + i * 4, params![i])
        }
        return p
    }

    static func opReq(dataPhase: UInt32, opCode: UInt32, txId: Int, params: [Int]?) -> [UInt8] {
        frame(tOperationReq, opBody(dataPhase: dataPhase, code: opCode, txId: txId, params: params))
    }

    static func opRsp(dataPhase: UInt32, respCode: UInt32, txId: Int, params: [Int]?) -> [UInt8] {
        frame(tOperationRsp, opBody(dataPhase: dataPhase, code: respCode, txId: txId, params: params))
    }

    struct Op {
        var dataPhase: UInt32 = 0
        var code: UInt32 = 0
        var txId: Int = 0
        var params: [Int] = []
    }

    static func parseOp(_ body: [UInt8]) throws -> Op {
        if body.count < 10 { throw PtpError.badFrame("操作包过短: \(body.count)") }
        var o = Op()
        o.dataPhase = UInt32(bitPattern: UInt32(i32(body, 0)))
        o.code = UInt32(u16(body, 4))
        o.txId = i32(body, 6)
        let n = (body.count - 10) / 4
        o.params = (0..<n).map { i32(body, 10 + $0 * 4) }
        return o
    }

    /// 扩展 Operation（参数区 + 内联 blob），与标准形式参数区偏移不同，必须用 parseOpBlob 解析。
    static func opBlob(dataPhase: UInt32, code: UInt32, txId: Int, params: [Int]?, blob: [UInt8]?) -> [UInt8] {
        let n = params?.count ?? 0
        let bl = blob?.count ?? 0
        var p = [UInt8](repeating: 0, count: 4 + 2 + 4 + 4 + n * 4 + 4 + bl)
        put32u(&p, 0, dataPhase)
        put16(&p, 4, Int(code & 0xFFFF))
        put32(&p, 6, txId)
        put32(&p, 10, n)
        for i in 0..<n { put32(&p, 14 + i * 4, params![i]) }
        let o = 14 + n * 4
        put32(&p, o, bl)
        if bl > 0, let b = blob {
            p.replaceSubrange(o + 4..<p.count, with: b)
        }
        return p
    }

    static func opReqBlob(opCode: UInt32, txId: Int, blob: [UInt8]?) -> [UInt8] {
        frame(tOperationReq, opBlob(dataPhase: dpDataIn, code: opCode, txId: txId, params: nil, blob: blob))
    }

    static func opReqBlobParams(opCode: UInt32, txId: Int, params: [Int]?, blob: [UInt8]?) -> [UInt8] {
        frame(tOperationReq, opBlob(dataPhase: dpDataIn, code: opCode, txId: txId, params: params, blob: blob))
    }

    static func opRspBlob(respCode: UInt32, txId: Int, params: [Int]?, blob: [UInt8]?) -> [UInt8] {
        frame(tOperationRsp, opBlob(dataPhase: dpDataIn, code: respCode, txId: txId, params: params, blob: blob))
    }

    struct OpBlob {
        var dataPhase: UInt32 = 0
        var code: UInt32 = 0
        var txId: Int = 0
        var params: [Int] = []
        var blob: [UInt8] = []
    }

    static func parseOpBlob(_ body: [UInt8]) throws -> OpBlob {
        if body.count < 18 { throw PtpError.badFrame("扩展响应包过短: \(body.count)") }
        var o = OpBlob()
        o.dataPhase = UInt32(bitPattern: UInt32(i32(body, 0)))
        o.code = UInt32(u16(body, 4))
        o.txId = i32(body, 6)
        let n = i32(body, 10)
        if n < 0 || 14 + n * 4 + 4 > body.count { throw PtpError.badFrame("扩展响应 paramCount 越界") }
        o.params = (0..<n).map { i32(body, 14 + $0 * 4) }
        let bl = i32(body, 14 + n * 4)
        if bl < 0 || 14 + n * 4 + 4 + bl > body.count { throw PtpError.badFrame("扩展响应 blobLen 越界") }
        if bl > 0 {
            o.blob = Array(body[(14 + n * 4 + 4)..<(14 + n * 4 + 4 + bl)])
        }
        return o
    }

    // MARK: Event

    static func event(evCode: UInt32, txId: Int, params: [Int]?) -> [UInt8] {
        let n = params?.count ?? 0
        var p = [UInt8](repeating: 0, count: 6 + n * 4)
        put16(&p, 0, Int(evCode & 0xFFFF))
        put32(&p, 2, txId)
        for i in 0..<n { put32(&p, 6 + i * 4, params![i]) }
        return frame(tEvent, p)
    }

    struct Ev {
        var code: UInt32 = 0
        var txId: Int = 0
        var params: [Int] = []
    }

    static func parseEvent(_ body: [UInt8]) throws -> Ev {
        if body.count < 6 { throw PtpError.badFrame("事件包过短: \(body.count)") }
        var e = Ev()
        e.code = UInt32(u16(body, 0))
        e.txId = i32(body, 2)
        let n = (body.count - 6) / 4
        e.params = (0..<n).map { i32(body, 6 + $0 * 4) }
        return e
    }

    // MARK: 数据阶段

    static func startData(txId: Int, total: Int64) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 12)
        put32(&p, 0, txId)
        put64(&p, 4, total)
        return frame(tStartData, p)
    }

    static func dataPacket(txId: Int, data: [UInt8]?) -> [UInt8] {
        let n = data?.count ?? 0
        var p = [UInt8](repeating: 0, count: 4 + n)
        put32(&p, 0, txId)
        if n > 0, let d = data {
            p.replaceSubrange(4..<p.count, with: d)
        }
        return frame(tData, p)
    }

    static func endData(txId: Int, data: [UInt8]?) -> [UInt8] {
        let n = data?.count ?? 0
        var p = [UInt8](repeating: 0, count: 4 + n)
        put32(&p, 0, txId)
        if n > 0, let d = data {
            p.replaceSubrange(4..<p.count, with: d)
        }
        return frame(tEndData, p)
    }

    static func cancel(txId: Int) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 4)
        put32(&p, 0, txId)
        return frame(tCancel, p)
    }

    static func txIdOf(_ body: [UInt8]) -> Int {
        body.count >= 4 ? i32(body, 0) : 0
    }

    static func totalOf(_ body: [UInt8]) throws -> Int64 {
        if body.count < 12 { throw PtpError.badFrame("Start Data 载荷过短") }
        return i64(body, 4)
    }

    // MARK: 厂商扩展：文件端口握手

    static func dataOpen(guid: [UInt8], connNo: Int, token: Int64) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 28)
        p.replaceSubrange(0..<16, with: guid)
        put32(&p, 16, connNo)
        put64(&p, 20, token)
        return frame(tDataOpen, p)
    }

    static func dataOpenAck() -> [UInt8] { frame(tDataOpenAck, []) }

    struct DataOpen {
        var guid: [UInt8] = []
        var connNo: Int = 0
        var token: Int64 = 0
    }

    static func parseDataOpen(_ body: [UInt8]) throws -> DataOpen {
        if body.count < 28 { throw PtpError.badFrame("DATA_OPEN 载荷过短") }
        var d = DataOpen()
        d.guid = Array(body[0..<16])
        d.connNo = i32(body, 16)
        d.token = i64(body, 20)
        return d
    }

    // MARK: UDP 发现

    static func probe(request: Bool, guid: [UInt8], friendlyName: String,
                      protoPort: Int, filePort: Int, pairingMode: Bool, paired: Bool) -> [UInt8] {
        let nl = nameLen(friendlyName)
        var p = [UInt8](repeating: 0, count: 16 + nl + 8)
        p.replaceSubrange(0..<16, with: guid)
        _ = writeName(&p, 16, friendlyName)
        let o = 16 + nl
        put16(&p, o, protoPort)
        put16(&p, o + 2, filePort)
        p[o + 4] = pairingMode ? 1 : 0
        p[o + 5] = paired ? 1 : 0
        return frame(request ? tProbeReq : tProbeResp, p)
    }

    struct Probe {
        var guid: [UInt8] = []
        var name: String = ""
        var protoPort: Int = 0
        var filePort: Int = 0
        var pairingMode: Bool = false
        var paired: Bool = false
    }

    static func parseProbe(_ body: [UInt8]) throws -> Probe {
        if body.count < 17 { throw PtpError.badFrame("探测包过短") }
        var pr = Probe()
        pr.guid = Array(body[0..<16])
        let (nm, next) = readName(body, 16)
        pr.name = nm
        if next + 8 <= body.count {
            pr.protoPort = u16(body, next)
            pr.filePort = u16(body, next + 2)
            pr.pairingMode = body[next + 4] != 0
            pr.paired = body[next + 5] != 0
        }
        return pr
    }

    static func hasVendorTag(_ name: String?) -> Bool {
        guard let n = name else { return false }
        return n.hasSuffix(vendorTag)
    }

    // MARK: 小工具

    static func hex(_ b: [UInt8]) -> String {
        b.map { String(format: "%02x", $0) }.joined()
    }

    static func unhex(_ s: String) -> [UInt8]? {
        let chars = Array(s)
        guard chars.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = hexDigit(chars[i]), let lo = hexDigit(chars[i + 1]) else { return nil }
            out.append(UInt8(hi << 4 | lo))
            i += 2
        }
        return out
    }

    private static func hexDigit(_ c: Character) -> Int? {
        switch c {
        case "0"..."9": return Int(c.asciiValue! - 48)
        case "a"..."f": return Int(c.asciiValue! - 87)
        case "A"..."F": return Int(c.asciiValue! - 55)
        default: return nil
        }
    }
}

/// 协议层错误。
enum PtpError: Error, LocalizedError {
    case io(String)
    case badFrame(String)
    case timeout(String)
    case protocolError(String)
    case initFailed(reason: UInt32)
    case closed

    var errorDescription: String? {
        switch self {
        case .io(let m), .badFrame(let m), .timeout(let m), .protocolError(let m): return m
        case .initFailed(let r):
            return "相机拒绝连接：Init Fail reason=0x\(String(format: "%02X", r))"
        case .closed: return "连接已关闭"
        }
    }
}

/// 字节流抽象：TCPStream / UdpSocket 都满足它。
protocol InputStreamLike {
    /// 读满 count 字节；EOF 时返回 nil（不足 count 则抛错）。
    func readFully(_ count: Int) throws -> [UInt8]?
}
