import SwiftUI

@main
struct AlphaSyncApp: App {
    @StateObject private var settings = SettingsStore.shared
    @StateObject private var connection = ConnectionCenter.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(connection)
                .preferredColorScheme(resolvedScheme)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                    // 回到前台：自动同步续跑
                    if LiveSync.shared.enabled {
                        LiveSync.shared.onConnectionEstablished(
                            guid: connection.camera?.guid ?? "",
                            host: connection.host ?? ""
                        )
                    }
                }
        }
    }

    private var resolvedScheme: ColorScheme? {
        switch settings.darkMode {
        case 1: return .light
        case 2: return .dark
        default: return nil
        }
    }
}

/// 根视图：三 Tab（主界面 / 文件 / 传输）+ 顶部连接状态条。
struct RootView: View {
    @EnvironmentObject private var connection: ConnectionCenter
    @State private var tab = 0

    var body: some View {
        NavigationStack {
            TabView(selection: $tab) {
                HomeView()
                    .tabItem { Label("主界面", systemImage: "camera") }
                    .tag(0)
                FilesView()
                    .tabItem { Label("文件", systemImage: "folder") }
                    .tag(1)
                TransfersView()
                    .tabItem { Label("传输", systemImage: "arrow.down.circle") }
                    .tag(2)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                ConnectionBanner()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: "settings") {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .navigationDestination(for: String.self) { dest in
                switch dest {
                case "settings": SettingsView()
                case "cameraDetail": CameraDetailView()
                default: EmptyView()
                }
            }
        }
    }
}

/// 顶部连接状态条。
struct ConnectionBanner: View {
    @EnvironmentObject private var connection: ConnectionCenter

    var body: some View {
        if let camera = connection.camera, connection.state == .connected {
            HStack(spacing: 8) {
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text(camera.name)
                    .font(.footnote.weight(.semibold))
                Spacer()
                Text(batteryText(camera.batteryPct))
                    .font(.footnote.monospacedDigit())
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
        } else if case .connecting = connection.state {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在连接…").font(.footnote)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
        } else if case .awaitingReconnect(let reason) = connection.state {
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash").font(.footnote)
                Text(reason).font(.footnote).lineLimit(1)
                Spacer()
                Button("重连") { connection.reconnect() }
                    .font(.footnote.weight(.semibold))
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
        } else {
            EmptyView()
        }
    }

    private func batteryText(_ pct: Int) -> String {
        pct >= 0 ? "🔋 \(pct)%" : ""
    }
}
