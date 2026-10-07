import Foundation
import SwiftUI

// MARK: - 相机信息

/// 相机设备信息（连接后从 DEVICE_INFO + PING 合并）。
struct CameraInfo: Equatable {
    let guid: String          // 16 位小写 hex
    let name: String
    let model: String
    let serial: String
    let firmware: String
    let region: String
    let apiVersion: String
    let androidVersion: String
    let androidSdk: Int
    let mode: String
    let ssid: String
    let protoPort: Int
    let filePort: Int

    // 实时字段（随 PING 更新）
    var batteryPct: Int      // -1 = 未知
    var lens: String
    var sdTotalBytes: Int64  // -1 = 未知
    var sdUsedBytes: Int64   // -1 = 未知

    var sdKnown: Bool { sdTotalBytes > 0 && sdUsedBytes >= 0 && sdUsedBytes <= sdTotalBytes }
    var sdUsedFraction: Double {
        sdKnown ? min(max(Double(sdUsedBytes) / Double(sdTotalBytes), 0), 1) : 0
    }

    /// 由 OP_DEVICE_INFO 的厂商 JSON 构造（缺失即未知/空串）。
    static func fromDeviceInfo(_ json: [String: Any]?, guid: String, fallbackName: String,
                               protoPort: Int, filePort: Int) -> CameraInfo? {
        guard let json = json else { return nil }
        let reportedName = json["name"] as? String ?? ""
        let (model, serialFromModel) = splitModelSerial(json["model"] as? String ?? "")
        let serial = (json["serial"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? serialFromModel ?? ""
        return CameraInfo(
            guid: guid,
            name: reportedName.isEmpty ? fallbackName : reportedName,
            model: model,
            serial: serial,
            firmware: json["firmware"] as? String ?? "",
            region: json["region"] as? String ?? "",
            apiVersion: json["apiVersion"] as? String ?? "",
            androidVersion: json["androidVersion"] as? String ?? "",
            androidSdk: (json["androidSdk"] as? NSNumber)?.intValue ?? -1,
            mode: json["mode"] as? String ?? "",
            ssid: json["ssid"] as? String ?? "",
            protoPort: protoPort,
            filePort: filePort,
            batteryPct: (json["batteryPct"] as? NSNumber)?.intValue ?? -1,
            lens: json["lens"] as? String ?? "",
            sdTotalBytes: -1,
            sdUsedBytes: -1
        )
    }

    static func placeholder(guid: String, name: String, protoPort: Int, filePort: Int) -> CameraInfo {
        CameraInfo(guid: guid, name: name, model: "", serial: "", firmware: "", region: "",
                   apiVersion: "", androidVersion: "", androidSdk: -1, mode: "", ssid: "",
                   protoPort: protoPort, filePort: filePort, batteryPct: -1, lens: "",
                   sdTotalBytes: -1, sdUsedBytes: -1)
    }

    func applyPing(batteryPct: Int, lens: String, sdTotal: Int64 = -1, sdUsed: Int64 = -1) -> CameraInfo {
        var c = self
        if (0...100).contains(batteryPct) { c.batteryPct = batteryPct }
        c.lens = lens
        if sdTotal >= 0 { c.sdTotalBytes = sdTotal }
        if sdUsed >= 0 { c.sdUsedBytes = sdUsed }
        return c
    }
}

/// 从可能被污染的字符串里拆出 (型号, 序列号?)。
func splitModelSerial(_ raw: String) -> (String, String?) {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty { return ("", nil) }
    // "ILCE-6300 SN:05186914" / "ILCE-6300 SN：05186914"
    if let m = s.range(of: #"^(.*?)\s*SN[:：]\s*(\S+)\s*$"#, options: [.regularExpression, .caseInsensitive]) {
        // Swift 无法直接取 group 字符串，用 NSString 方式
        let ns = s as NSString
        let rx = try? NSRegularExpression(pattern: #"^(.*?)\s*SN[:：]\s*(\S+)\s*$"#, options: [.caseInsensitive])
        if let rx = rx, let match = rx.firstMatch(in: s, options: [], range: NSRange(location: 0, length: ns.length)) {
            let model = ns.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-· "))
            let serial = ns.substring(with: match.range(at: 2))
            return (model, serial)
        }
        return (s, nil)
    }
    // "ILCE-6300 05186914"（尾部纯数字 ≥6 位）
    if let m = s.range(of: #"^(.*\S)\s+(\d{6,})\s*$"#, options: .regularExpression) {
        let ns = s as NSString
        let rx = try? NSRegularExpression(pattern: #"^(.*\S)\s+(\d{6,})\s*$"#)
        if let rx = rx, let match = rx.firstMatch(in: s, options: [], range: NSRange(location: 0, length: ns.length)) {
            let model = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            let serial = ns.substring(with: match.range(at: 2))
            return (model, serial)
        }
        return (s, nil)
    }
    return (s, nil)
}

// MARK: - 已配对相机

struct PairedCamera: Identifiable, Hashable {
    let peerDeviceId: String   // 16 hex，主键
    let peerName: String
    let peerModel: String
    let peerSerial: String
    let pairedAt: Int64
    let lastSeenAt: Int64
    let lastIp: String
    let lastPort: Int
    let protoVersion: Int

    var id: String { peerDeviceId }

    var displayModel: String {
        if !peerModel.isEmpty { return splitModelSerial(peerModel).0 }
        if !peerName.isEmpty { return splitModelSerial(peerName).0 }
        return ""
    }

    var displaySerial: String {
        if !peerSerial.isEmpty { return peerSerial }
        let fromModel = splitModelSerial(peerModel.isEmpty ? peerName : peerModel).1
        return fromModel ?? ""
    }
}

// MARK: - 传输项

enum TransferState: Equatable {
    case queued
    case downloading(progress: Double)
    case paused(progress: Double)
    case done
    case failed(String)
}

struct TransferItem: Identifiable {
    let id = UUID()
    let cameraGuid: String
    let cameraPath: String
    let deviceDir: String
    let name: String
    var state: TransferState
    var bytesDone: Int64
    var bytesTotal: Int64
}

// MARK: - 设置

enum DarkModeChoice: Int {
    case system = 0
    case light = 1
    case dark = 2
}
