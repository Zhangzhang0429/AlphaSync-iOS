import Foundation
import CryptoKit
import UIKit

extension Notification.Name {
    /// 缩略图/预览写入完成，网格可据此刷新。
    static let alphasyncThumbUpdated = Notification.Name("alphasync.thumb.updated")
}

/// 缩略图/预览磁盘缓存 —— 镜像安卓端 `ThumbStore.kt` 的缓存与取图语义。
///
/// 目录结构（Caches/AlphaSync）：
/// - thumbs/<md5(相机guid+路径)>.jpg   —— 小图
/// - previews/<md5(相机guid+路径)>.jpg —— 大预览（1616×1080 内嵌 JPEG）
/// - exif/<md5>.json                    —— EXIF 侧车（预览捆绑包里拆出）
///
/// 小图批量走相机端缩略图队列（THUMB_QUEUE_BEGIN + GET_OBJECT_BATCH "T" 行）；
/// 大预览按需单取（GET_OBJECT "P"），或对可见区做批量预取。
final class ThumbStore {

    static let shared = ThumbStore()

    struct Key: Hashable {
        let cameraGuid: String   // 相机设备码 16 hex
        let path: String         // 相机内路径（/DCIM/...）
    }

    private let ioQueue = DispatchQueue(label: "alphasync.thumbs.io")
    private let cacheQueue = DispatchQueue(label: "alphasync.thumbs.cache")

    private var baseDir: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("AlphaSync", isDirectory: true)
    }
    private var thumbDir: URL { baseDir.appendingPathComponent("thumbs", isDirectory: true) }
    private var previewDir: URL { baseDir.appendingPathComponent("previews", isDirectory: true) }
    private var exifDir: URL { baseDir.appendingPathComponent("exif", isDirectory: true) }

    /// 已请求过但尚未完成的小图（去重）。
    private var inflight = Set<String>()
    private let lock = NSLock()

    private init() {
        for d in [thumbDir, previewDir, exifDir] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }

    private func cacheKey(_ value: String) -> String {
        let md5 = Insecure.MD5.hash(data: Data(value.utf8))
        return md5.map { String(format: "%02x", $0) }.joined()
    }

    private func smallFile(_ key: Key) -> URL {
        thumbDir.appendingPathComponent(cacheKey(key.cameraGuid + "|" + key.path) + ".jpg")
    }
    private func previewFile(_ key: Key) -> URL {
        previewDir.appendingPathComponent(cacheKey(key.cameraGuid + "|" + key.path) + ".jpg")
    }
    private func exifFile(_ key: Key) -> URL {
        exifDir.appendingPathComponent(cacheKey(key.cameraGuid + "|" + key.path) + ".json")
    }

    // MARK: 读

    func smallThumb(_ key: Key) -> UIImage? {
        let f = smallFile(key)
        guard FileManager.default.fileExists(atPath: f.path) else { return nil }
        return UIImage(contentsOfFile: f.path)
    }

    func previewImage(_ key: Key) -> UIImage? {
        let f = previewFile(key)
        guard FileManager.default.fileExists(atPath: f.path) else { return nil }
        return UIImage(contentsOfFile: f.path)
    }

    func readExifJSON(_ key: Key) -> String? {
        let f = exifFile(key)
        return FileManager.default.fileExists(atPath: f.path) ? (try? String(contentsOf: f, encoding: .utf8)) : nil
    }

    func orientationOf(_ key: Key) -> Int {
        guard let json = readExifJSON(key),
              let o = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let orient = o["orientation"] as? Int else { return 1 }
        return orient
    }

    // MARK: 小图批量取（相机缩略图队列 + 批量下载）

    /// 请求一批小图（去重后向相机登记队列并批量取回）。
    func requestSmall(host: String, keys: [Key]) {
        lock.lock()
        let fresh = keys.filter { !inflight.contains(id($0)) && smallThumb($0) == nil }
        for k in fresh { inflight.insert(id(k)) }
        lock.unlock()
        guard !fresh.isEmpty else { return }

        let hostNow = host
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            let batchKeys = Array(fresh.prefix(ObjectRepository.batchItemLimit))
            guard !batchKeys.isEmpty else { return }
            // ① 向相机登记缩略图队列（相机端据此预热小图）
            _ = ObjectRepository.shared.thumbQueue(host: hostNow, op: PtpCodec.opThumbQueueBegin,
                                                   paths: batchKeys.map { $0.path })
            // ② 批量取小图
            let items = batchKeys.map { (path: $0.path, kind: PtpCodec.kindThumb) }
            guard let ticket = ObjectRepository.shared.openBatchTicket(host: hostNow, items: items) else {
                self.release(fresh)
                return
            }
            _ = ObjectRepository.shared.downloadBatch(ticket, count: batchKeys.count, labels: batchKeys.map { $0.path }) { index, bytes in
                if let bytes = bytes, index < batchKeys.count {
                    self.writeSmall(batchKeys[index], bytes)
                }
            }
            _ = ObjectRepository.shared.thumbQueue(host: hostNow, op: PtpCodec.opThumbQueueCancel, paths: [])
            self.release(fresh)
        }
    }

    /// 取单张大预览（磁盘缓存未命中则从相机拉取）。
    func fetchPreview(host: String, key: Key, completion: @escaping (UIImage?) -> Void) {
        if let img = previewImage(key) { completion(img); return }
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            let path = key.path
            let bytes = ObjectRepository.shared.fetchVirtualPreview(host: host, cameraPath: path)
            guard let bytes = bytes else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            // 预览捆绑包：4 字节大端长度 N + N 字节 EXIF JSON + JPEG（FF D8 开头）
            var imageBytes = bytes
            var exifJSON: String? = nil
            if bytes.count > 4 {
                let n = (Int(bytes[0]) << 24) | (Int(bytes[1]) << 16) | (Int(bytes[2]) << 8) | Int(bytes[3])
                if n >= 0 && n <= bytes.count - 4 {
                    let jpg = Array(bytes[(4 + n)...])
                    if jpg.count > 2 && jpg[0] == 0xFF && jpg[1] == 0xD8 {
                        imageBytes = jpg
                        if n > 0 {
                            exifJSON = String(decoding: bytes[4..<(4 + n)], as: UTF8.self)
                        }
                    }
                }
            }
            self.writePreview(key, imageBytes)
            if let exifJSON = exifJSON {
                try? FileManager.default.createDirectory(at: self.exifDir, withIntermediateDirectories: true)
                try? exifJSON.data(using: .utf8)?.write(to: self.exifFile(key))
            }
            let img = UIImage(data: Data(imageBytes))
            DispatchQueue.main.async { completion(img) }
        }
    }

    // MARK: 写 / 清理

    private func writeSmall(_ key: Key, _ bytes: [UInt8]) {
        try? FileManager.default.createDirectory(at: thumbDir, withIntermediateDirectories: true)
        try? Data(bytes).write(to: smallFile(key))
        NotificationCenter.default.post(name: .alphasyncThumbUpdated, object: nil)
        pruneIfNeeded()
    }

    private func writePreview(_ key: Key, _ bytes: [UInt8]) {
        try? FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)
        try? Data(bytes).write(to: previewFile(key))
        pruneIfNeeded()
    }

    func cacheSizeBytes() -> Int64 {
        var total: Int64 = 0
        for d in [thumbDir, previewDir, exifDir] {
            if let enumerator = FileManager.default.enumerator(at: d, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let url as URL in enumerator {
                    if let v = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        total += Int64(v)
                    }
                }
            }
        }
        return total
    }

    func clearCache() {
        cacheQueue.async { [weak self] in
            guard let self = self else { return }
            for d in [self.thumbDir, self.previewDir, self.exifDir] {
                if let items = try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil) {
                    for f in items { try? FileManager.default.removeItem(at: f) }
                }
            }
        }
    }

    /// 简单 LRU 修剪：按修改时间淘汰最旧文件，直到低于预算。
    private func pruneIfNeeded() {
        let limit = SettingsStore.shared.cacheLimitBytes
        cacheQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.cacheSizeBytes() > limit else { return }
            var files: [(URL, Date)] = []
            for d in [self.thumbDir, self.previewDir, self.exifDir] {
                if let items = try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey]) {
                    for f in items {
                        let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                        files.append((f, date))
                    }
                }
            }
            files.sort { $0.1 < $1.1 }
            var used = self.cacheSizeBytes()
            for (f, _) in files {
                if used <= limit { break }
                let sz = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                try? FileManager.default.removeItem(at: f)
                used -= Int64(sz)
            }
        }
    }

    private func id(_ key: Key) -> String { key.cameraGuid + "|" + key.path }

    private func release(_ keys: [Key]) {
        lock.lock()
        for k in keys { inflight.remove(id(k)) }
        lock.unlock()
    }
}
