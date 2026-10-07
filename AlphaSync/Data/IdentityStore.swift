import Foundation
import UIKit

/// 本机身份 —— 镜像安卓端 `IdentityRepo.kt`。
/// deviceId：首次启动用 SecureRandom 生成 8 字节，此后固定；guid16 = deviceId(8B) 补 8 个零。
final class IdentityStore {

    static let shared = IdentityStore()

    private let defaults = UserDefaults.standard
    private let deviceIdKey = "identity.deviceId"
    private let friendlyKey = "identity.friendlyName"

    private(set) var deviceId: String = ""
    private(set) var deviceIdBytes: [UInt8] = []
    private(set) var guid16: [UInt8] = []

    var friendlyName: String {
        get { defaults.string(forKey: friendlyKey) ?? Self.defaultFriendlyName() }
        set {
            let v = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(v.isEmpty ? Self.defaultFriendlyName() : v, forKey: friendlyKey)
        }
    }

    private init() {
        if let hex = defaults.string(forKey: deviceIdKey), hex.count == 16, let b = PtpCodec.unhex(hex) {
            deviceId = hex.lowercased()
            deviceIdBytes = b
        } else {
            var rnd = [UInt8](repeating: 0, count: 8)
            for i in 0..<8 { rnd[i] = UInt8.random(in: 0...255) }
            deviceIdBytes = rnd
            deviceId = PtpCodec.hex(rnd)
            defaults.set(deviceId, forKey: deviceIdKey)
        }
        var g = [UInt8](repeating: 0, count: 16)
        g.replaceSubrange(0..<8, with: deviceIdBytes)
        guid16 = g
    }

    /// 默认友好名 = 本机对外显示的名字（iPhone 型号）。
    private static func defaultFriendlyName() -> String {
        let model = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? "iPhone" : model
    }
}
