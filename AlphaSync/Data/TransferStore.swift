import Foundation
import Combine

/// 传输队列 —— 镜像安卓端 `TransferStore.kt` + `DownloadService.kt` 的核心语义：
/// 断点续传（.part）、设备目录隔离、进度合并上报、取消/暂停/重试。
final class TransferStore: ObservableObject {

    static let shared = TransferStore()

    @Published private(set) var items: [TransferItem] = []

    private let queueLock = NSLock()
    private let workerQueue = DispatchQueue(label: "alphasync.transfer.worker")
    private var activeGuids: Set<String> = []
    private var cancelledPaths: Set<String> = []

    private init() {}

    // MARK: 队列查询

    func items(forCamera guid: String) -> [TransferItem] {
        queueLock.lock(); defer { queueLock.unlock() }
        return items.filter { $0.cameraGuid == guid }
    }

    func count(forCamera guid: String) -> (active: Int, done: Int, failed: Int) {
        queueLock.lock(); defer { queueLock.unlock() }
        let mine = items.filter { $0.cameraGuid == guid }
        return (
            active: mine.filter { isActive($0.state) }.count,
            done: mine.filter { $0.state == .done }.count,
            failed: mine.filter { if case .failed = $0.state { return true } else { return false } }.count
        )
    }

    private func isActive(_ s: TransferState) -> Bool {
        switch s {
        case .queued, .downloading, .paused: return true
        case .done, .failed: return false
        }
    }

    // MARK: 入队

    /// 入队一组文件（设备目录在入队时钉死）。
    func enqueue(cameraGuid: String, deviceDir: String, entries: [ObjectRepository.FtpEntry]) {
        queueLock.lock()
        var added: [TransferItem] = []
        for e in entries where !e.isDir {
            // 跳过已在队列中的同路径
            if items.contains(where: { $0.cameraGuid == cameraGuid && $0.cameraPath == e.path }) { continue }
            let item = TransferItem(
                cameraGuid: cameraGuid,
                cameraPath: e.path,
                deviceDir: deviceDir,
                name: e.name,
                state: .queued,
                bytesDone: 0,
                bytesTotal: e.size
            )
            items.append(item)
            added.append(item)
        }
        queueLock.unlock()
        objectWillChange.send()
        guard !added.isEmpty else { return }
        pumpIfIdle(cameraGuid: cameraGuid)
    }

    // MARK: 处理

    func pauseAll(forCamera guid: String) {
        queueLock.lock()
        for i in items.indices where items[i].cameraGuid == guid && isActive(items[i].state) {
            if case .downloading(let p) = items[i].state {
                items[i].state = .paused(progress: p)
            }
        }
        queueLock.unlock()
        objectWillChange.send()
    }

    func resumeAll(forCamera guid: String) {
        pumpIfIdle(cameraGuid: guid)
    }

    func cancel(path: String) {
        queueLock.lock()
        cancelledPaths.insert(path)
        items.removeAll { $0.cameraPath == path }
        queueLock.unlock()
        objectWillChange.send()
    }

    func removeFinished(forCamera guid: String) {
        queueLock.lock()
        items.removeAll { $0.cameraGuid == guid && $0.state == .done }
        queueLock.unlock()
        objectWillChange.send()
    }

    func removeAll(forCamera guid: String) {
        queueLock.lock()
        for i in items where i.cameraGuid == guid && isActive(i.state) {
            cancelledPaths.insert(i.cameraPath)
        }
        items.removeAll { $0.cameraGuid == guid }
        queueLock.unlock()
        objectWillChange.send()
    }

    func retryFailed(forCamera guid: String) {
        queueLock.lock()
        for i in items.indices where items[i].cameraGuid == guid {
            if case .failed = items[i].state {
                items[i].state = .queued
                items[i].bytesDone = 0
            }
        }
        queueLock.unlock()
        objectWillChange.send()
        pumpIfIdle(cameraGuid: guid)
    }

    // MARK: 工作循环

    /// 若该相机的队列非空且无进行中任务，则开始处理下一个。
    private func pumpIfIdle(cameraGuid: String) {
        workerQueue.async { [weak self] in
            guard let self = self else { return }
            self.processNext(cameraGuid: cameraGuid)
        }
    }

    private func processNext(cameraGuid: String) {
        // 单相机串行：一台相机同一时刻只跑一个下载（弱电台上多流并发反而更慢）
        queueLock.lock()
        if activeGuids.contains(cameraGuid) {
            queueLock.unlock()
        objectWillChange.send()
            return
        }
        guard let idx = items.firstIndex(where: { $0.cameraGuid == cameraGuid && $0.state == .queued }) else {
            queueLock.unlock()
        objectWillChange.send()
            return
        }
        activeGuids.insert(cameraGuid)
        items[idx].state = .downloading(progress: 0)
        let item = items[idx]
        queueLock.unlock()
        objectWillChange.send()

        // 断点续传：目标 .part 已有字节 → 从该偏移续传
        let host = ConnectionCenter.shared.hostFor(cameraGuid: item.cameraGuid) ?? ""
        guard !host.isEmpty else {
            markFailed(cameraGuid: cameraGuid, path: item.cameraPath, reason: "相机未连接")
            queueLock.lock()
            activeGuids.remove(cameraGuid)
            queueLock.unlock()
        objectWillChange.send()
            processNext(cameraGuid: cameraGuid)
            return
        }
        let finalURL = StorageSinks.downloadsRoot.appendingPathComponent(StorageSinks.localRelPath(deviceDir: item.deviceDir, cameraPath: item.cameraPath))
        let partURL = URL(fileURLWithPath: finalURL.path + ".part")
        var startOffset = StorageSinks.partBytes(for: partURL)

        // 续传前校验源对象未变（stat size 与入队时一致才续传，否则从头）
        do {
            let st = try ObjectRepository.shared.stat(host: host, path: item.cameraPath)
            if st.size != item.bytesTotal || startOffset > st.size {
                startOffset = 0
            }
        } catch {
            // stat 失败：从已知偏移续传，靠下载侧校验兜底
        }

        do {
            let handle = try StorageSinks.partHandle(for: partURL)
            if startOffset == 0 {
                try handle.truncate(atOffset: 0)
            } else {
                try handle.seek(toOffset: UInt64(startOffset))
            }
            let result = ObjectRepository.shared.pumpToStream(
                host: host,
                path: item.cameraPath,
                startOffset: startOffset,
                out: handle,
                cancelled: { [weak self] in
                    guard let self = self else { return true }
                    self.queueLock.lock()
                    let c = self.cancelledPaths.contains(item.cameraPath)
                    self.queueLock.unlock()
                    return c
                },
                onProgress: { [weak self] done in
                    self?.updateProgress(cameraGuid: cameraGuid, path: item.cameraPath, done: done)
                }
            )
            try handle.close()

            switch result {
            case .completed:
                // 提交前校验大小
                try StorageSinks.commit(partURL: partURL, finalURL: finalURL, expectedBytes: item.bytesTotal)
                markDone(cameraGuid: cameraGuid, path: item.cameraPath)
                if SettingsStore.shared.saveToPhotos && StorageSinks.photosSaveable(item.name) {
                    StorageSinks.saveToPhotoLibrary(fileURL: finalURL)
                }
            case .cancelled:
                markRemoved(cameraGuid: cameraGuid, path: item.cameraPath)
            case .failed:
                markFailed(cameraGuid: cameraGuid, path: item.cameraPath, reason: "下载失败")
            }
        } catch {
            markFailed(cameraGuid: cameraGuid, path: item.cameraPath, reason: error.localizedDescription)
        }

        queueLock.lock()
        activeGuids.remove(cameraGuid)
        queueLock.unlock()
        objectWillChange.send()

        // 处理下一个
        processNext(cameraGuid: cameraGuid)
    }

    private func updateProgress(cameraGuid: String, path: String, done: Int64) {
        queueLock.lock()
        if let i = items.firstIndex(where: { $0.cameraGuid == cameraGuid && $0.cameraPath == path }) {
            items[i].bytesDone = done
            if case .downloading = items[i].state {
                let total = items[i].bytesTotal > 0 ? items[i].bytesTotal : 1
                items[i].state = .downloading(progress: min(max(Double(done) / Double(total), 0), 1))
            }
        }
        queueLock.unlock()
        objectWillChange.send()
    }

    private func markDone(cameraGuid: String, path: String) {
        queueLock.lock()
        if let i = items.firstIndex(where: { $0.cameraGuid == cameraGuid && $0.cameraPath == path }) {
            items[i].state = .done
            items[i].bytesDone = items[i].bytesTotal
        }
        cancelledPaths.remove(path)
        queueLock.unlock()
        objectWillChange.send()
    }

    private func markFailed(cameraGuid: String, path: String, reason: String) {
        queueLock.lock()
        if let i = items.firstIndex(where: { $0.cameraGuid == cameraGuid && $0.cameraPath == path }) {
            items[i].state = .failed(reason)
        }
        queueLock.unlock()
        objectWillChange.send()
    }

    private func markRemoved(cameraGuid: String, path: String) {
        queueLock.lock()
        items.removeAll { $0.cameraGuid == cameraGuid && $0.cameraPath == path }
        cancelledPaths.remove(path)
        queueLock.unlock()
        objectWillChange.send()
    }
}
