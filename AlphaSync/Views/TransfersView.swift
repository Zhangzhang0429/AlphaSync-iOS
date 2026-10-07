import SwiftUI

/// 传输页：队列、进度、暂停/继续/重试/删除。
struct TransfersView: View {
    @EnvironmentObject private var connection: ConnectionCenter
    @StateObject private var store = TransferStore.shared

    private var cameraGuid: String? { connection.camera?.guid }

    var body: some View {
        Group {
            if store.items.isEmpty {
                ContentUnavailableView {
                    Label("还没有传输任务", systemImage: "arrow.down.circle")
                } description: {
                    Text("在文件页长按选中文件后点「开始传输」，或开启自动同步")
                }
            } else {
                List {
                    ForEach(store.items) { item in
                        TransferRow(item: item, cameraGuid: item.cameraGuid)
                    }
                    .onDelete { indexSet in
                        let toDelete = indexSet.map { store.items[$0] }
                        for t in toDelete {
                            store.cancel(path: t.cameraPath)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("传输")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !store.items.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("重试失败任务") {
                            if let g = cameraGuid { store.retryFailed(forCamera: g) }
                        }
                        Button("删除已完成") {
                            if let g = cameraGuid { store.removeFinished(forCamera: g) }
                        }
                        Button("删除全部", role: .destructive) {
                            if let g = cameraGuid { store.removeAll(forCamera: g) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }
}

struct TransferRow: View {
    let item: TransferItem
    let cameraGuid: String
    @StateObject private var store = TransferStore.shared

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.body).lineLimit(1)
                switch item.state {
                case .queued:
                    Text("等待中").font(.caption).foregroundStyle(.secondary)
                case .downloading(let p):
                    ProgressView(value: p)
                        .tint(.accentColor)
                    Text("\(Int(p * 100))% · \(byteText(item.bytesDone)) / \(byteText(item.bytesTotal))")
                        .font(.caption2).foregroundStyle(.secondary)
                case .paused(let p):
                    ProgressView(value: p).tint(.orange)
                    Text("已暂停 \(Int(p * 100))%").font(.caption).foregroundStyle(.orange)
                case .done:
                    Label("已完成", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                case .failed(let reason):
                    Label("失败：\(reason)", systemImage: "xmark.circle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            switch item.state {
            case .done:
                if let url = localURL(item) {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                }
            case .paused:
                Button {
                    store.resumeAll(forCamera: cameraGuid)
                } label: {
                    Image(systemName: "play.circle.fill").foregroundStyle(.green)
                }
                .buttonStyle(.borderless)
            case .downloading:
                Button {
                    store.pauseAll(forCamera: cameraGuid)
                } label: {
                    Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
            case .failed:
                Button {
                    store.retryFailed(forCamera: cameraGuid)
                } label: {
                    Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.borderless)
            case .queued:
                EmptyView()
            }
        }
        .padding(.vertical, 2)
    }

    private func byteText(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    private func localURL(_ item: TransferItem) -> URL? {
        let rel = StorageSinks.localRelPath(deviceDir: item.deviceDir, cameraPath: item.cameraPath)
        let url = StorageSinks.downloadsRoot.appendingPathComponent(rel)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
