import Foundation

/// 配对流程客户端 —— 镜像安卓端 `PairingClient.kt`。
///
/// 线格式：
/// ```
/// ① PAIR_BEGIN    req blob = 本机设备名(UTF-8)   → rsp blob = devIdC(8)
/// ② PAIR_EXCHANGE req blob = 6 位配对码(ASCII)   → rsp = RC_OK / RC_PAIRING_FAILED
/// ```
struct PairingClient {

    static let codeLen = 6
    static let deviceIdLen = 8

    private let sendReq: (UInt32, Int, [UInt8]) throws -> Void
    private let recvRsp: () throws -> PtpCodec.OpBlob

    struct Result {
        let cameraDeviceId: [UInt8]
    }

    struct PairingFailedError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct DeviceBusyError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    init(sendReq: @escaping (UInt32, Int, [UInt8]) throws -> Void,
         recvRsp: @escaping () throws -> PtpCodec.OpBlob) {
        self.sendReq = sendReq
        self.recvRsp = recvRsp
    }

    /// 第一步：报上设备名，换回相机设备码；相机收到这一条才会生成并显示配对码。
    func begin(deviceName: String) throws -> Result {
        try sendReq(PtpCodec.opPairBegin, PtpIpClient.txBegin, Array(deviceName.utf8))
        let r1 = try recvRsp()
        if r1.code == PtpCodec.rcPairingFailed {
            throw PairingFailedError(message: "相机未开启配对模式")
        }
        if r1.code == PtpCodec.rcDeviceBusy {
            throw DeviceBusyError(message: "相机正被其他设备占用")
        }
        guard r1.code == PtpCodec.rcOk else {
            throw PairingFailedError(message: String(format: "配对被拒绝（0x%04X）", r1.code))
        }
        guard r1.blob.count >= Self.deviceIdLen else {
            throw PairingFailedError(message: "PAIR_BEGIN 应答过短")
        }
        return Result(cameraDeviceId: Array(r1.blob[0..<Self.deviceIdLen]))
    }

    /// 第二步：把用户看着相机屏输入的 6 位码交给相机核对。必须在 begin 之后调用。
    func exchange(code: String) throws {
        let clean = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count == Self.codeLen, clean.allSatisfy({ $0.isWholeNumber }) else {
            throw PairingFailedError(message: "配对码必须是 \(Self.codeLen) 位数字")
        }
        try sendReq(PtpCodec.opPairExchange, PtpIpClient.txExchange, Array(clean.utf8))
        let r2 = try recvRsp()
        guard r2.code == PtpCodec.rcOk else {
            throw PairingFailedError(message: "配对码不正确或已失效")
        }
    }

    /// 中止本次配对（best-effort）。
    func abort() {
        try? sendReq(PtpCodec.opPairAbort, PtpIpClient.txAbort, [])
    }
}
