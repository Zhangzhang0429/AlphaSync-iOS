import SwiftUI
import UIKit
import QuickLook

/// 已下载文件浏览（应用 Documents/AlphaSync，即“文件”App 里的 AlphaSync 目录）。
struct LocalPhotosView: View {
    @State private var items: [LocalItem] = []
    @State private var previewURL: URL?
    @State private var refreshID = UUID()

    struct LocalItem: Identifiable {
        let url: URL
        var id: String { url.path }
        var name: String { url.lastPathComponent }
        var sizeText: String {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        }
        var isImage: Bool {
            ["jpg", "jpeg", "heic", "png", "arw"].contains(url.pathExtension.lowercased())
        }
        var thumbnail: UIImage? {
            guard isImage else { return nil }
            return UIImage(contentsOfFile: url.path)
        }
    }
    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView {
                    Label("还没有下载的文件", systemImage: "tray")
                } description: {
                    Text("下载完成后，文件会出现在这里（同时可在「文件」App 的 AlphaSync 文件夹中查看）")
                }
            } else {
                List(items) { item in
                    HStack(spacing: 12) {
                        if let thumb = item.thumbnail {
                            Image(uiImage: thumb)
                                .resizable()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        } else {
                            Image(systemName: "doc")
                                .frame(width: 56, height: 56)
                        }
                        VStack(alignment: .leading) {
                            Text(item.name).font(.body).lineLimit(1)
                            Text(item.sizeText).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            Button {
                                previewURL = item.url
                            } label: {
                                Label("预览", systemImage: "eye")
                            }
                            ShareLink(item: item.url) {
                                Label("分享", systemImage: "square.and.arrow.up")
                            }
                            if StorageSinks.photosSaveable(item.name) {
                                Button("保存到相册") {
                                    StorageSinks.saveToPhotoLibrary(fileURL: item.url)
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
        }
        .id(refreshID)
        .navigationTitle("本地文件")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .onAppear { reload() }
        .sheet(isPresented: Binding(
            get: { previewURL != nil },
            set: { if !$0 { previewURL = nil } }
        )) {
            if let url = previewURL {
                QuickLookPreview(url: url)
            }
        }
    }

    private func reload() {
        let root = StorageSinks.downloadsRoot
        let fm = FileManager.default
        var list: [LocalItem] = []
        if let files = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey]) {
            // 只列文件（含相机子目录下的）
            let all = files.flatMap { dir -> [URL] in
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue {
                    return (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                }
                return [dir]
            }
            list = all.filter { !$0.path.hasSuffix(".part") }.map { LocalItem(url: $0) }
                .sorted { $0.url.path > $1.url.path }
        }
        items = list
    }
}

/// QuickLook 预览容器（图片 / 视频 / RAW 都能看）。
struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url) }

    class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(_ url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
