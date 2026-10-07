import Foundation
import Combine

/// 自动同步（边拍边传）—— 镜像安卓端 `LiveTransferCenter.kt` 的巡检语义：
/// 建立基准 → 轮询各影像目录的条目计数 → 计数变化时重新列表 → 把新文件入队传输。
///
/// ⚠ iOS 限制：系统不允许 App 在后台保持长连接。自动同步在 App 前台运行（或
/// 开启“同步时保持屏幕常亮”）时有效；退到后台后 iOS 会暂停网络，恢复前台自动续跑。
final class LiveSync: ObservableObject {

    static let shared = LiveSync()

    @Published private(set) var enabled = false
    @Published private(set) var active = false
    @Published private(set) var statusText = "未启用"
    @Published private(set) var syncedCount = 0

    private var baseline: [String: String] = [:]          // 影像目录路径 -> 条目计数
    private var patrolTimer: Timer?
    private var sessionGuid: String?
    private let queue = DispatchQueue(label: "alphasync.livesync")
    private let lock = NSLock()

    private init() {}

    func enable() {
        guard !enabled else { return }
        enabled = true
        statusText = "正在建立基准…"
        startPatrolIfConnected()
    }

    func disable() {
        enabled = false
        active = false
        stopPatrol()
        statusText = "未启用"
    }

    func onConnectionEstablished(guid: String, host: String) {
        guard enabled else { return }
        sessionGuid = guid
        startPatrolIfConnected()
    }

    func onConnectionLost() {
        stopPatrol()
        active = false
        statusText = "连接已断开，等待重连…"
    }

    // MARK: 巡检

    private func startPatrolIfConnected() {
        stopPatrol()
        guard enabled,
              let host = ConnectionCenter.shared.host,
              let guid = ConnectionCenter.shared.camera?.guid else { return }
        sessionGuid = guid
        queue.async { [weak self] in
            guard let self = self else { return }
            guard let imageDirs = self.buildBaseline(host: host) else {
                DispatchQueue.main.async {
                    self.active = false
                    self.statusText = "无法读取相机目录"
                }
                return
            }
            self.lock.lock(); self.baseline = imageDirs; self.lock.unlock()
            DispatchQueue.main.async {
                guard self.enabled else { return }
                self.active = true
                self.statusText = "正在监听新照片…"
                self.startPolling(host: host, guid: guid)
            }
        }
    }

    private func startPolling(host: String, guid: String) {
        let timer = Timer(timeInterval: 4.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.pollOnce(host: host, guid: guid)
        }
        RunLoop.main.add(timer, forMode: .common)
        patrolTimer = timer
    }

    private func stopPatrol() {
        patrolTimer?.invalidate()
        patrolTimer = nil
        lock.lock(); baseline.removeAll(); lock.unlock()
    }

    /// 建立基准：递归扫描影像目录，记录每个目录的条目计数。
    private func buildBaseline(host: String) -> [String: String]? {
        var dirs: [String: String] = [:]
        guard let roots = try? ObjectRepository.shared.list(host: host, dir: "/") else { return nil }
        for root in roots where root.isDir {
            scanImageDir(host: host, dir: root.path, into: &dirs)
        }
        return dirs
    }

    private func scanImageDir(host: String, dir: String, into out: inout [String: String]) {
        guard let entries = try? ObjectRepository.shared.list(host: host, dir: dir) else { return }
        var hasMedia = false
        for e in entries {
            if e.isDir {
                scanImageDir(host: host, dir: e.path, into: &out)
            } else if isMedia(e.name) {
                hasMedia = true
            }
        }
        if hasMedia {
            out[dir] = ""
        }
    }

    private func isMedia(_ name: String) -> Bool {
        let ext = name.split(separator: ".").last.map { String($0).lowercased() } ?? ""
        return ["jpg", "jpeg", "arw", "heic", "png", "mp4", "mov"].contains(ext)
    }

    private func pollOnce(host: String, guid: String) {
        guard enabled,
              ObjectRepository.shared.isConnected(host) else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let dirs = self.baseline
            self.lock.unlock()
            for dir in dirs.keys {
                guard let count = ObjectRepository.shared.dirCount(host: host, dir: dir) else { continue }
                self.lock.lock()
                let old = self.baseline[dir]
                self.baseline[dir] = String(count)
                self.lock.unlock()
                if old == String(count) { continue }
                // 计数变化 → 重新列表，入队新文件
                self.enqueueNew(host: host, guid: guid, dir: dir)
            }
        }
    }

    private func enqueueNew(host: String, guid: String, dir: String) {
        guard let entries = try? ObjectRepository.shared.list(host: host, dir: dir) else { return }
        let deviceDir = StorageSinks.deviceFolder(for: guid)
        let newFiles = entries.filter { !$0.isDir }
        TransferStore.shared.enqueue(cameraGuid: guid, deviceDir: deviceDir, entries: newFiles)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.syncedCount += newFiles.count
            self.statusText = newFiles.isEmpty ? "监听中" : "发现 \(newFiles.count) 个新文件，已加入传输"
        }
    }
}
