import Foundation
import Combine

/// 连接中心 —— 镜像安卓端 `ConnectionCenter.kt` 的状态机与事件处理。
final class ConnectionCenter: ObservableObject {

    static let shared = ConnectionCenter()

    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case pairing(codeShown: Bool)
        case awaitingReconnect(reason: String)
        case error(String)
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var camera: CameraInfo?
    @Published private(set) var discovered: [Discovery.DiscoveredCamera] = []
    @Published private(set) var isScanning = false
    @Published private(set) var scanError: String?
    @Published private(set) var statusMessage: String?

    private(set) var targetGuid: String?
    var host: String?

    /// 每台相机最近一次成功连接的 IP（传输层用）。
    private var hostByGuid: [String: String] = [:]

    private var heartbeatTimer: Timer?
    private var retryTimer: Timer?
    private var eventSessionGuid: String?
    private var pairingInProgress = false
    private var pairingHostAddress: String?
    private let queue = DispatchQueue(label: "alphasync.connection")

    private init() {
        // 自动连接上次选中的相机（应用启动时）
        autoConnectLast()
    }

    // MARK: 查询

    func hostFor(cameraGuid: String) -> String? {
        queue.sync { hostByGuid[cameraGuid.lowercased()] }
    }

    func isConnected(toGuid guid: String) -> Bool {
        state == .connected && camera?.guid.lowercased() == guid.lowercased()
    }

    /// 是否处于“没有可用连接”的状态（断线或出错），自动同步据此停摆。
    var isOffline: Bool {
        switch state {
        case .disconnected, .error: return true
        default: return false
        }
    }

    // MARK: 扫描

    /// 手动/自动扫描。thorough = 手动“扫描设备”（列全，不做早退）。
    func startPairingScan(force: Bool = false) {
        isScanning = true
        scanError = nil
        queue.async { [weak self] in
            guard let self = self else { return }
            let preferred = PairingStore.shared.all().compactMap { $0.lastIp.isEmpty ? nil : $0.lastIp }
            let found = Discovery.scan(preferredHosts: preferred, thorough: force)
            DispatchQueue.main.async {
                self.isScanning = false
                self.discovered = found
            }
        }
    }

    // MARK: 连接

    func autoConnectLast() {
        let guid = SettingsStore.shared.lastConnectedDevice
        guard !guid.isEmpty else { return }
        startConnect(guid: guid)
    }

    func reconnect() {
        startConnect(guid: targetGuid ?? SettingsStore.shared.lastConnectedDevice)
    }

    /// 扫描结果里点“连接”：先看是否已配对。
    func connectTo(cam: Discovery.DiscoveredCamera) {
        targetGuid = cam.guidHex
        SettingsStore.shared.updateLastDevice(cam.guidHex)
        if PairingStore.shared.contains(cam.guidHex) {
            startConnect(guid: cam.guidHex)
        } else {
            requestPair(cam: cam)
        }
    }

    func switchTo(guidHex: String) {
        targetGuid = guidHex.lowercased()
        SettingsStore.shared.updateLastDevice(targetGuid!)
        if PairingStore.shared.contains(targetGuid!) {
            startConnect(guid: targetGuid!)
        } else if let cam = discovered.first(where: { $0.guidHex.lowercased() == targetGuid! }) {
            requestPair(cam: cam)
        } else {
            state = .error("未找到该相机，请先扫描")
        }
    }

    private func startConnect(guid: String) {
        targetGuid = guid.lowercased()
        state = .connecting
        statusMessage = "正在连接…"
        queue.async { [weak self] in
            guard let self = self else { return }
            self.connectInBackground(guid: guid)
        }
    }

    private func connectInBackground(guid: String) {
        let guidLower = guid.lowercased()
        guard let record = PairingStore.shared.find(guidLower) else {
            DispatchQueue.main.async { self.state = .error("该相机尚未配对") }
            return
        }

        // 优先用配对记录里的地址快连；失败则广播扫描兜底
        var cam: Discovery.DiscoveredCamera? = nil
        if !record.lastIp.isEmpty {
            cam = Discovery.DiscoveredCamera(
                host: record.lastIp,
                protoPort: record.lastPort > 0 ? record.lastPort : 15740,
                filePort: record.lastPort > 0 ? record.lastPort : 15740,
                cameraGuid16: PtpCodec.unhex(guidLower) ?? [],
                name: record.peerName,
                pairingMode: false
            )
        }
        if cam == nil {
            let found = Discovery.scan(preferredHosts: record.lastIp.isEmpty ? [] : [record.lastIp],
                                      thorough: false, sweep: true)
            cam = found.first { $0.guidHex.lowercased() == guidLower }
        }
        guard let cam = cam else {
            DispatchQueue.main.async {
                self.state = .awaitingReconnect(reason: "找不到相机（\(record.peerName)），请确认相机端已开启无线服务")
            }
            return
        }

        self.host = cam.host
        queue.sync { hostByGuid[guidLower] = cam.host }
        let outcome = ObjectRepository.shared.connect(
            host: cam.host,
            protoPort: cam.protoPort,
            guid16: IdentityStore.shared.guid16,
            friendlyName: IdentityStore.shared.friendlyName + " " + PtpCodec.vendorTag,
            onEvent: { [weak self] code, txId, params in
                self?.handleEvent(code: code, txId: txId, params: params)
            }
        )
        switch outcome {
        case .ok:
            // 记录最近可见信息 + 拉取设备信息 + 起心跳
            PairingStore.shared.touch(peerDeviceId: guidLower, ip: cam.host, port: cam.protoPort)
            PairingStore.shared.updateProtoVersion(guidLower, PtpIpClient.protoVersion)
            let info = ObjectRepository.shared.deviceInfo(host: cam.host)
            let placeholder = CameraInfo.placeholder(
                guid: guidLower,
                name: record.peerName,
                protoPort: cam.protoPort,
                filePort: cam.filePort
            )
            var finalInfo = CameraInfo.fromDeviceInfo(info, guid: guidLower,
                                                      fallbackName: record.peerName,
                                                      protoPort: cam.protoPort,
                                                      filePort: cam.filePort) ?? placeholder
            // 连接上下文里拿到的相机名优先（Init Command Ack 回的那份）
            if let s = ObjectRepository.shared.sessionOf(cam.host), !s.cameraName.isEmpty {
                finalInfo = CameraInfo(
                    guid: guidLower, name: s.cameraName, model: finalInfo.model,
                    serial: finalInfo.serial, firmware: finalInfo.firmware,
                    region: finalInfo.region, apiVersion: finalInfo.apiVersion,
                    androidVersion: finalInfo.androidVersion, androidSdk: finalInfo.androidSdk,
                    mode: finalInfo.mode, ssid: finalInfo.ssid,
                    protoPort: cam.protoPort, filePort: cam.filePort,
                    batteryPct: finalInfo.batteryPct, lens: finalInfo.lens,
                    sdTotalBytes: finalInfo.sdTotalBytes, sdUsedBytes: finalInfo.sdUsedBytes
                )
            }
            DispatchQueue.main.async {
                self.camera = finalInfo
                self.state = .connected
                self.statusMessage = "已连接 \(finalInfo.name)"
                self.startHeartbeat(host: cam.host)
            }
        case .notPaired:
            // 相机侧已解除配对：清本地记录
            PairingStore.shared.remove(guidLower)
            DispatchQueue.main.async {
                self.state = .error("相机已解除配对，请重新配对")
            }
        case .busy:
            DispatchQueue.main.async {
                self.state = .error("相机正被其他设备占用")
            }
        case .failed:
            DispatchQueue.main.async {
                self.state = .awaitingReconnect(reason: "连接失败，请检查手机与相机是否在同一 Wi-Fi/热点下")
            }
        }
    }

    // MARK: 事件

    private func handleEvent(code: UInt32, txId: Int, params: [Int]) {
        switch code {
        case PtpCodec.evPairedRemoved:
            // 相机侧解除配对：清本地记录并断开
            if let guid = camera?.guid {
                PairingStore.shared.remove(guid)
            }
            disconnect()
            DispatchQueue.main.async { self.state = .error("相机已解除与本机的配对") }
        case PtpCodec.evAppExiting:
            disconnect()
            DispatchQueue.main.async { self.state = .disconnected }
            statusMessage = "相机端已退出"
        case PtpCodec.evModeSwitching:
            disconnect()
            DispatchQueue.main.async { self.state = .disconnected }
            statusMessage = "相机正在切换连接方式，已断开"
        case PtpCodec.evDisconnecting:
            let reason = params.first ?? Int(PtpCodec.discReasonOther)
            let text: String
            switch UInt32(reason) {
            case PtpCodec.discReasonPairing: text = "相机进入配对模式，已断开"
            case PtpCodec.discReasonError: text = "相机端服务异常，已断开"
            default: text = "相机主动断开连接"
            }
            disconnect()
            DispatchQueue.main.async { self.state = .disconnected }
            statusMessage = text
        case PtpCodec.evEnteringBackground:
            // 相机进入后台运行：链路可能断一次，准备自动重连
            statusMessage = "相机已进入后台运行，尝试重连…"
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.reconnectIfWasConnected()
            }
        case PtpCodec.evThumbProgress:
            break // 缩略图进度由 ThumbStore 自行管理
        default:
            break
        }
    }

    private func reconnectIfWasConnected() {
        if let host = host, ObjectRepository.shared.isConnected(host) {
            return
        }
        DispatchQueue.main.async {
            self.state = .awaitingReconnect(reason: "等待重连…")
        }
        startConnect(guid: targetGuid ?? SettingsStore.shared.lastConnectedDevice)
    }

    // MARK: 心跳

    private func startHeartbeat(host: String) {
        stopHeartbeat()
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if !ObjectRepository.shared.isConnected(host) { return }
            do {
                let info = try ObjectRepository.shared.ping(host: host)
                DispatchQueue.main.async {
                    guard let cam = self.camera else { return }
                    self.camera = cam.applyPing(batteryPct: info.batteryPct, lens: info.lens,
                                                sdTotal: info.sdTotal, sdUsed: info.sdUsed)
                }
            } catch {
                // 心跳失败：连续失败由控制连接断开回调兜底
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    // MARK: 断开

    func disconnect(reason: String? = nil) {
        stopHeartbeat()
        if let host = host {
            ObjectRepository.shared.disconnect(host)
        }
        host = nil
        DispatchQueue.main.async {
            self.camera = nil
            if let r = reason {
                self.statusMessage = r
            }
        }
    }

    // MARK: 配对

    func requestPair(cam: Discovery.DiscoveredCamera) {
        guard !pairingInProgress else { return }
        pairingInProgress = true
        targetGuid = cam.guidHex
        pairingHostAddress = cam.host
        SettingsStore.shared.updateLastDevice(cam.guidHex)
        DispatchQueue.main.async { self.state = .pairing(codeShown: false) }
        queue.async { [weak self] in
            guard let self = self else { return }
            let outcome = ObjectRepository.shared.pairBegin(
                host: cam.host,
                protoPort: cam.protoPort,
                guid16: IdentityStore.shared.guid16,
                friendlyName: IdentityStore.shared.friendlyName
            )
            switch outcome {
            case .paired:
                DispatchQueue.main.async { self.state = .pairing(codeShown: true) }
            case .busy:
                self.pairingInProgress = false
                DispatchQueue.main.async { self.state = .error("相机正被其他设备占用，请稍后再试") }
            case .failed:
                self.pairingInProgress = false
                DispatchQueue.main.async { self.state = .error("配对失败：无法与相机建立连接") }
            }
        }
    }

    func cancelPair() {
        pairingInProgress = false
        ObjectRepository.shared.pairAbort()
        DispatchQueue.main.async { self.state = .disconnected }
    }

    func submitPairCode(code: String) {
        guard let guid = targetGuid, pairingInProgress, let addr = pairingHostAddress else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            let outcome = ObjectRepository.shared.pairExchange(
                host: addr,
                code: code,
                onEvent: { [weak self] c, t, p in self?.handleEvent(code: c, txId: t, params: p) }
            )
            DispatchQueue.main.async {
                switch outcome {
                case .paired:
                    self.pairingInProgress = false
                    self.state = .connected
                    self.statusMessage = "配对成功"
                    // 配对成功：补一次连接信息并拉设备信息
                    self.refreshAfterPair(guid: guid)
                case .busy:
                    self.pairingInProgress = false
                    self.state = .error("相机正被其他设备占用")
                case .failed:
                    self.state = .pairing(codeShown: true)
                    self.statusMessage = "配对码不正确或已失效，请重试"
                }
            }
        }
    }

    private func refreshAfterPair(guid: String) {
        guard let cam = discovered.first(where: { $0.guidHex.lowercased() == guid.lowercased() }) else { return }
        self.host = cam.host
        queue.sync { hostByGuid[guid.lowercased()] = cam.host }
        PairingStore.shared.touch(peerDeviceId: guid.lowercased(), ip: cam.host, port: cam.protoPort)
        let info = ObjectRepository.shared.deviceInfo(host: cam.host)
        let placeholder = CameraInfo.placeholder(guid: guid.lowercased(), name: cam.name,
                                                 protoPort: cam.protoPort, filePort: cam.filePort)
        self.camera = CameraInfo.fromDeviceInfo(info, guid: guid.lowercased(),
                                                fallbackName: cam.name,
                                                protoPort: cam.protoPort,
                                                filePort: cam.filePort) ?? placeholder
        self.startHeartbeat(host: cam.host)
    }

    // MARK: 解除配对

    /// 解除配对：请相机删记录 + 清本地记录。
    func unpair(peerDeviceId: String) {
        if let host = hostFor(cameraGuid: peerDeviceId) {
            _ = ObjectRepository.shared.pairRemove(host: host)
        }
        PairingStore.shared.remove(peerDeviceId)
        if camera?.guid.lowercased() == peerDeviceId.lowercased() {
            disconnect()
        }
    }
}
