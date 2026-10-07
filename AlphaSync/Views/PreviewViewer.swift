import SwiftUI
import UIKit

/// 预览器：大图预览 + EXIF 信息 + 下载/保存/分享。
struct PreviewViewer: View {
    let entry: ObjectRepository.FtpEntry
    let host: String

    @EnvironmentObject private var connection: ConnectionCenter
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var loading = false
    @State private var failed = false
    @State private var showExif = false
    @State private var exifPairs: [(String, String)] = []
    @State private var showShare = false
    @State private var downloaded: URL?
    @State private var toast: String?

    private var cameraGuid: String { connection.camera?.guid ?? "" }
    private var key: ThumbStore.Key { ThumbStore.Key(cameraGuid: cameraGuid, path: entry.path) }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image = image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding()
                } else if loading {
                    ProgressView().tint(.white)
                } else if failed {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.white)
                        Text("无法获取预览").foregroundStyle(.white)
                        Button("重试") { load() }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showExif = true } label: { Image(systemName: "info.circle") }
                    Button { shareOrSave() } label: { Image(systemName: "square.and.arrow.up") }
                }
            }
            .navigationTitle(entry.name)
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $showExif) {
            ExifSheet(pairs: exifPairs, name: entry.name)
        }
        .sheet(isPresented: $showShare) {
            if let url = downloaded {
                ShareSheet(items: [url])
            }
        }
        .onAppear { load() }
        .overlay(alignment: .bottom) {
            if let toast = toast {
                Text(toast)
                    .font(.footnote)
                    .padding(8)
                    .background(.black.opacity(0.75))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                    .padding(.bottom, 24)
            }
        }
    }

    private func load() {
        loading = true
        failed = false
        ThumbStore.shared.fetchPreview(host: host, key: key) { img in
            loading = false
            if let img = img {
                image = img
                loadExif()
            } else {
                failed = true
            }
        }
    }

    private func loadExif() {
        guard let json = ThumbStore.shared.readExifJSON(key),
              let o = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return }
        var pairs: [(String, String)] = []
        for (k, v) in o {
            if let s = v as? String, !s.isEmpty { pairs.append((displayKey(k), s)) }
            else if let n = v as? NSNumber { pairs.append((displayKey(k), n.stringValue)) }
        }
        exifPairs = pairs
    }

    private func displayKey(_ k: String) -> String {
        switch k {
        case "orientation": return "方向"
        case "width": return "宽度"
        case "height": return "高度"
        case "model": return "机型"
        case "lens": return "镜头"
        case "fNumber": return "光圈"
        case "exposureTime": return "快门"
        case "iso": return "ISO"
        case "focalLength": return "焦距"
        case "dateTime": return "拍摄时间"
        default: return k
        }
    }

    private func shareOrSave() {
        // 先确保已下载原图，再分享/保存
        let deviceDir = StorageSinks.deviceFolder(for: cameraGuid)
        let rel = StorageSinks.localRelPath(deviceDir: deviceDir, cameraPath: entry.path)
        let finalURL = StorageSinks.downloadsRoot.appendingPathComponent(rel)
        if FileManager.default.fileExists(atPath: finalURL.path) {
            downloaded = finalURL
            showShare = true
        } else {
            toast = "尚未下载，请先在文件页或传输页下载原图"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { toast = nil }
        }
    }
}

/// EXIF 信息弹窗。
struct ExifSheet: View {
    let pairs: [(String, String)]
    let name: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if pairs.isEmpty {
                    Text("暂无 EXIF 信息")
                }
                ForEach(pairs, id: \.0) { k, v in
                    HStack {
                        Text(k).foregroundStyle(.secondary)
                        Spacer()
                        Text(v).multilineTextAlignment(.trailing)
                    }
                }
            }
            .navigationTitle("照片信息 · \(name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

/// 系统分享面板。
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
