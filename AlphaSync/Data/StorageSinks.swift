import Foundation
import Photos
import UIKit

/// 下载落盘通道：应用 Documents 目录（“文件”App 可见）+ 可选保存到系统相册。
/// 传输写 <name>.part，commit() 原子改名 —— 断点续传语义的基础。
enum StorageSinks {

    /// 下载根目录：Documents/AlphaSync（在“文件”App 中可见）。
    static var downloadsRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("AlphaSync", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 设备子目录名：`设备型号_SN码_设备码前8位`（例如 `ILCE-6300_05186914_a1339c31`）。
    /// 每台相机的文件落在自己的子目录里，避免互相覆盖。
    static func deviceFolder(for guidHex: String?) -> String {
        let rec = guidHex?.isEmpty == false ? PairingStore.shared.find(guidHex!) : nil
        let model = rec?.peerModel.trimmingCharacters(in: .whitespaces) ?? ""
        let serial = rec?.peerSerial.trimmingCharacters(in: .whitespaces) ?? ""
        let base: String
        if !model.isEmpty && !serial.isEmpty { base = model + "_" + serial }
        else if !model.isEmpty { base = model }
        else if !serial.isEmpty { base = serial }
        else { base = "" }
        let code = shortCode(guidHex)
        let raw: String
        if base.isEmpty { raw = code.isEmpty ? "unknown" : code }
        else if code.isEmpty { raw = base }
        else { raw = base + "_" + code }
        return sanitizeDirName(raw)
    }

    private static func shortCode(_ guidHex: String?) -> String {
        guard let g = guidHex, g.count >= 8 else { return "" }
        return String(g.prefix(8))
    }

    private static func sanitizeDirName(_ name: String) -> String {
        var s = name
        for ch in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"] {
            s = s.replacingOccurrences(of: ch, with: "_")
        }
        var filtered = ""
        for c in s.unicodeScalars {
            filtered.append(Character(c.value < 32 ? "_" : c))
        }
        s = filtered.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        return s.isEmpty ? "unknown" : s
    }

    /// 落盘相对路径 = `设备子目录/相机内路径`（去前导 /）。
    static func localRelPath(deviceDir: String, cameraPath: String) -> String {
        deviceDir + "/" + cameraPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// 按扩展名猜 MIME / 相册可保存性。
    static func mimeOf(_ name: String) -> String {
        let ext = name.split(separator: ".").last.map { String($0).lowercased() } ?? ""
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        default: return "application/octet-stream"
        }
    }

    /// 是否可保存到系统相册（jpg/heic/mp4/mov）。
    static func photosSaveable(_ name: String) -> Bool {
        let ext = name.split(separator: ".").last.map { String($0).lowercased() } ?? ""
        return ["jpg", "jpeg", "heic", "png", "mp4", "mov"].contains(ext)
    }

    // MARK: 落盘

    /// 打开（或创建）目标 .part 文件，返回 FileHandle（append 模式）。
    static func partHandle(for url: URL) throws -> FileHandle {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        return try FileHandle(forWritingTo: url)
    }

    /// .part 现有字节数。
    static func partBytes(for partURL: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: partURL.path)[.size] as? NSNumber)?
            .int64Value ?? 0
    }

    /// 将已验证完整的 .part 提交为最终文件（原子改名）。
    static func commit(partURL: URL, finalURL: URL, expectedBytes: Int64) throws {
        guard partBytes(for: partURL) == expectedBytes else {
            throw PtpError.io("断点大小不一致：\(partBytes(for: partURL)) != \(expectedBytes)")
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: finalURL.path) {
            try? fm.removeItem(at: finalURL)
        }
        try fm.moveItem(at: partURL, to: finalURL)
        let size = (try? fm.attributesOfItem(atPath: finalURL.path)[.size] as? NSNumber)?.int64Value ?? -1
        guard size == expectedBytes else {
            throw PtpError.io("最终文件大小不一致")
        }
    }

    static func discard(partURL: URL) {
        try? FileManager.default.removeItem(at: partURL)
    }

    /// 保存到系统相册（jpg/mp4/mov）。需要授权。
    static func saveToPhotoLibrary(fileURL: URL) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let ext = fileURL.pathExtension.lowercased()
        if ["mp4", "mov"].contains(ext) {
            PHPhotoLibrary.requestAuthorization { status in
                guard status == .authorized || status == .limited else { return }
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
                }) { _, _ in }
            }
        } else {
            PHPhotoLibrary.requestAuthorization { status in
                guard status == .authorized || status == .limited else { return }
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
                }) { _, _ in }
            }
        }
    }
}
