import SwiftUI

/// 主界面：已配对相机列表 + 扫描 + 连接状态 + 自动同步开关 + 相机信息卡。
struct HomeView: View {
    @EnvironmentObject private var connection: ConnectionCenter
    @State private var showPairing = false
    @State private var scannedOnce = false

    var body: some View {
        List {
            // 已配对相机
            if !PairingStore.shared.all().isEmpty {
                Section("已配对相机") {
                    ForEach(PairingStore.shared.all()) { cam in
                        Button {
                            connection.switchTo(guidHex: cam.peerDeviceId)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(cam.peerName).font(.body)
                                    Text(cam.displayModel).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if connection.isConnected(toGuid: cam.peerDeviceId) {
                                    Text("已连接").font(.caption).foregroundStyle(.green)
                                }
                            }
                        }
                    }
                }
            }

            // 当前相机信息卡
            if let camera = connection.camera, connection.state == .connected {
                Section("当前相机") {
                    NavigationLink(value: "cameraDetail") {
                        CameraCard(camera: camera)
                    }
                }
            }

            // 自动同步
            Section {
                Toggle(isOn: Binding(
                    get: { LiveSync.shared.enabled },
                    set: { on in
                        if on { LiveSync.shared.enable() } else { LiveSync.shared.disable() }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自动同步").font(.body)
                        Text(LiveSync.shared.statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("新拍摄的照片会自动传输到手机（前台运行有效，iOS 限制后台长连接）")
            }

            // 扫描结果
            Section("附近设备") {
                if connection.isScanning {
                    HStack { ProgressView(); Text("正在扫描…").font(.footnote) }
                } else {
                    Button {
                        connection.startPairingScan(force: true)
                        scannedOnce = true
                    } label: {
                        Label("扫描设备", systemImage: "magnifyingglass")
                    }
                    if scannedOnce && connection.discovered.isEmpty {
                        Text("未发现相机。请确认相机端已开启无线服务，且手机与相机在同一 Wi-Fi/热点下。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(connection.discovered, id: \.guidHex) { cam in
                        Button {
                            connection.connectTo(cam: cam)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(cam.name).font(.body)
                                    Text("\(cam.host):\(cam.protoPort)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if cam.pairingMode {
                                    Text("可配对").font(.caption).foregroundStyle(.orange)
                                } else if PairingStore.shared.contains(cam.guidHex) {
                                    Text("已配对").font(.caption).foregroundStyle(.green)
                                } else {
                                    Text("未配对").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }

            // 状态提示
            if let msg = connection.statusMessage {
                Section {
                    Text(msg).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("AlphaSync")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPairing) {
            PairingView()
        }
        .onChange(of: connection.state) { _, newState in
            if case .pairing = newState {
                showPairing = true
            }
            if case .connected = newState, let guid = connection.camera?.guid, let host = connection.host {
                LiveSync.shared.onConnectionEstablished(guid: guid, host: host)
            }
            if connection.isOffline {
                LiveSync.shared.onConnectionLost()
            }
        }
        .onAppear {
            connection.startPairingScan(force: false)
        }
    }
}

/// 相机信息卡：电量 / 镜头 / SD 容量。
struct CameraCard: View {
    let camera: CameraInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(camera.name).font(.headline)
                Spacer()
                if camera.batteryPct >= 0 {
                    Label("\(camera.batteryPct)%", systemImage: "battery.75")
                        .font(.footnote)
                }
            }
            if !camera.lens.isEmpty {
                Text("镜头：\(camera.lens)").font(.footnote).foregroundStyle(.secondary)
            }
            if camera.sdKnown {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SD 卡：\(ByteCountFormatter.string(fromByteCount: camera.sdUsedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: camera.sdTotalBytes, countStyle: .file))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ProgressView(value: camera.sdUsedFraction)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
