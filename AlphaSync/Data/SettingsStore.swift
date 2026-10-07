import Foundation
import Combine

/// 全局设置（UserDefaults + 观察）。镜像安卓端 `SettingsRepo.kt`。
final class SettingsStore: ObservableObject {

    static let shared = SettingsStore()

    @Published var friendlyName: String {
        didSet { defaults.set(friendlyName, forKey: "settings.friendlyName") }
    }
    @Published var darkMode: Int {      // 0 跟随系统 / 1 浅色 / 2 深色（默认深色）
        didSet { defaults.set(darkMode, forKey: "settings.darkMode") }
    }
    @Published var dynamicColor: Bool {
        didSet { defaults.set(dynamicColor, forKey: "settings.dynamicColor") }
    }
    @Published var cacheLimitBytes: Int64 {
        didSet { defaults.set(cacheLimitBytes, forKey: "settings.cacheLimitBytes") }
    }
    /// 上次选中的相机设备码（进软件自动连它）。
    @Published var lastConnectedDevice: String {
        didSet { defaults.set(lastConnectedDevice, forKey: "settings.lastConnectedDevice") }
    }
    /// 下载文件是否同时保存到系统相册（仅 jpg/mp4/mov）。
    @Published var saveToPhotos: Bool {
        didSet { defaults.set(saveToPhotos, forKey: "settings.saveToPhotos") }
    }

    static let cacheLimitOptions: [Int64] = [
        256 * 1024 * 1024,
        512 * 1024 * 1024,
        1024 * 1024 * 1024,
        2048 * 1024 * 1024,
    ]

    private let defaults = UserDefaults.standard

    private init() {
        let d = UserDefaults.standard
        friendlyName = d.string(forKey: "settings.friendlyName") ?? IdentityStore.shared.friendlyName
        darkMode = d.object(forKey: "settings.darkMode") as? Int ?? 2
        dynamicColor = d.object(forKey: "settings.dynamicColor") as? Bool ?? true
        cacheLimitBytes = d.object(forKey: "settings.cacheLimitBytes") as? Int64 ?? (512 * 1024 * 1024)
        lastConnectedDevice = d.string(forKey: "settings.lastConnectedDevice") ?? ""
        saveToPhotos = d.object(forKey: "settings.saveToPhotos") as? Bool ?? false
    }

    func updateLastDevice(_ guidHex: String) {
        let g = guidHex.lowercased()
        if g.isEmpty || g == lastConnectedDevice { return }
        lastConnectedDevice = g
    }

    static func formatCacheLimit(_ v: Int64) -> String {
        let gb = Double(v) / (1024.0 * 1024.0 * 1024.0)
        if gb >= 1.0 {
            if gb == gb.rounded() { return "\(Int64(gb)) GB" }
            return String(format: "%.1f GB", gb)
        }
        return "\(v / (1024 * 1024)) MB"
    }
}
