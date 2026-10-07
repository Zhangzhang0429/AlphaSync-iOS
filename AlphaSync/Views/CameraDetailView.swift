import SwiftUI

/// 相机信息页：型号/序列号/固件/地区/系统版本/热点 SSID + 实时电量/镜头/SD。
struct CameraDetailView: View {
    @EnvironmentObject private var connection: ConnectionCenter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if let camera = connection.camera {
                Section("基本信息") {
                    row("型号", camera.model)
                    row("序列号", camera.serial)
                    row("固件", camera.firmware)
                    row("地区", camera.region)
                    row("API 版本", camera.apiVersion)
                    row("系统版本", camera.androidVersion)
                    row("连接方式", camera.mode)
                    row("热点 SSID", camera.ssid)
                }
                Section("实时状态") {
                    row("电量", camera.batteryPct >= 0 ? "\(camera.batteryPct)%" : "—")
                    row("镜头", camera.lens.isEmpty ? "—" : camera.lens)
                    if camera.sdKnown {
                        row("SD 卡已用", ByteCountFormatter.string(fromByteCount: camera.sdUsedBytes, countStyle: .file))
                        row("SD 卡总量", ByteCountFormatter.string(fromByteCount: camera.sdTotalBytes, countStyle: .file))
                    }
                }
            } else {
                Text("未连接相机")
            }

            Section {
                Button(role: .destructive) {
                    if let guid = connection.camera?.guid {
                        connection.unpair(peerDeviceId: guid)
                    }
                    dismiss()
                } label: {
                    Text("解除配对")
                }
            }

            Section {
                Button(role: .destructive) {
                    connection.disconnect(reason: "已手动断开")
                    dismiss()
                } label: {
                    Text("断开连接")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("相机信息")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(.secondary)
            Spacer()
            Text(v.isEmpty ? "—" : v).multilineTextAlignment(.trailing)
        }
    }
}
