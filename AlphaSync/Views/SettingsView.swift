import SwiftUI

/// 设置页。
struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var connection: ConnectionCenter
    @State private var showUnpairConfirm = false
    @State private var cacheSizeText = "…"

    var body: some View {
        List {
            Section {
                TextField("设备名称", text: $settings.friendlyName)
            } header: {
                Text("本机")
            } footer: {
                Text("相机端会显示这个名字（超过 16 字自动截断）")
            }

            Section("外观") {
                Picker("深色模式", selection: $settings.darkMode) {
                    Text("跟随系统").tag(0)
                    Text("浅色").tag(1)
                    Text("深色").tag(2)
                }
                Toggle("动态取色", isOn: $settings.dynamicColor)
            }

            Section("缓存") {
                Picker("缓存上限", selection: $settings.cacheLimitBytes) {
                    ForEach(SettingsStore.cacheLimitOptions, id: \.self) { v in
                        Text(SettingsStore.formatCacheLimit(v)).tag(v)
                    }
                }
                HStack {
                    Text("当前占用")
                    Spacer()
                    Text(cacheSizeText).foregroundStyle(.secondary)
                }
                Button("立即清理缓存") {
                    ThumbStore.shared.clearCache()
                    refreshCacheSize()
                }
            }

            Section {
                Toggle("同时保存到系统相册", isOn: $settings.saveToPhotos)
            } header: {
                Text("下载")
            } footer: {
                Text("开启后，jpg/mp4/mov 下载完成会同时保存到「照片」App（RAW 文件只能存文件目录）")
            }

            Section("已配对相机") {
                let paired = PairingStore.shared.all()
                if paired.isEmpty {
                    Text("尚未配对任何相机").foregroundStyle(.secondary)
                } else {
                    ForEach(paired) { cam in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(cam.peerName)
                                Text(cam.displayModel).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("解除配对", role: .destructive) {
                                connection.unpair(peerDeviceId: cam.peerDeviceId)
                            }
                            .font(.footnote)
                        }
                    }
                }
            }

            Section("关于") {
                HStack {
                    Text("协议版本")
                    Spacer()
                    Text(PtpIpClient.formatProtoVersion(PtpIpClient.protoVersion))
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("本机设备码")
                    Spacer()
                    Text(IdentityStore.shared.deviceId)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refreshCacheSize() }
    }

    private func refreshCacheSize() {
        DispatchQueue.global(qos: .utility).async {
            let size = ThumbStore.shared.cacheSizeBytes()
            DispatchQueue.main.async {
                cacheSizeText = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            }
        }
    }
}
