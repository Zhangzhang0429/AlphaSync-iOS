import SwiftUI
import UIKit
import Combine

/// 文件页：目录浏览 + 缩略图网格 + 多选下载 + 预览。
///
/// 数据源是相机端 PTP/IP 会话。默认排序“新→旧”（reverse 分页）。
struct FilesView: View {
    @EnvironmentObject private var connection: ConnectionCenter

    @State private var currentDir = "/"
    @State private var breadcrumbs: [(String, String)] = [("根", "/")]
    @State private var entries: [ObjectRepository.FtpEntry] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var selected: Set<String> = []
    @State private var selectionMode = false
    @State private var previewPath: ObjectRepository.FtpEntry?
    @State private var showDownloadDialog = false
    @State private var nextOffset = 0
    @State private var hasMore = false

    private var host: String? { connection.host }

    var body: some View {
        Group {
            if connection.state != .connected || host == nil {
                ContentUnavailableView {
                    Label("未连接相机", systemImage: "camera.fill")
                } description: {
                    Text("请先在主界面连接相机，再浏览文件")
                }
            } else {
                VStack(spacing: 0) {
                    breadcrumbBar
                    if isLoading && entries.isEmpty {
                        ProgressView("加载中…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let err = loadError, entries.isEmpty {
                        ContentUnavailableView {
                            Label("读取失败", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(err)
                        } actions: {
                            Button("重试") { loadCurrentDir() }
                        }
                    } else {
                        grid
                    }
                }
            }
        }
        .navigationTitle("文件")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if selectionMode {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { exitSelection() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("全选") { toggleSelectAll() }
                }
            }
        }
        .onAppear { if entries.isEmpty { loadCurrentDir() } }
        .onChange(of: connection.state) { _, newState in
            if case .connected = newState { loadCurrentDir() }
            if case .disconnected = newState { entries = [] }
        }
        .confirmationDialog("下载", isPresented: $showDownloadDialog, titleVisibility: .visible) {
            Button("下载所选 (\(selected.count))") {
                startDownload()
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(item: $previewPath) { entry in
            PreviewViewer(entry: entry, host: host ?? "")
        }
    }

    // MARK: 目录导航

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(breadcrumbs.enumerated()), id: \.offset) { idx, crumb in
                    Button {
                        navigateTo(index: idx)
                    } label: {
                        Text(idx == breadcrumbs.count - 1 ? crumb.0 : crumb.0 + " ›")
                            .font(.footnote)
                            .foregroundStyle(idx == breadcrumbs.count - 1 ? Color.primary : Color.accentColor)
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    private func navigateTo(index: Int) {
        let target = breadcrumbs[index].1
        let crumbSlice = Array(breadcrumbs.prefix(index + 1))
        breadcrumbs = crumbSlice
        currentDir = target
        exitSelection()
        loadCurrentDir()
    }

    private func enterDir(_ entry: ObjectRepository.FtpEntry) {
        breadcrumbs.append((entry.name, entry.path))
        currentDir = entry.path
        exitSelection()
        loadCurrentDir()
    }

    private func loadCurrentDir() {
        guard let host = host else { return }
        isLoading = true
        loadError = nil
        let dir = currentDir
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // 倒序分页：新→旧
                var page = try ObjectRepository.shared.listPage(host: host, dir: dir, offset: 0, limit: 256, reverse: true)
                let firstPage = page
                let hasMore = page.hasMore
                let next = page.nextOffset
                DispatchQueue.main.async {
                    self.entries = firstPage.entries
                    self.nextOffset = next
                    self.hasMore = hasMore
                    self.isLoading = false
                    self.requestThumbs(for: firstPage.entries)
                }
                // 继续翻页直到读完（简化：iOS 端一次性拉完当前目录所有页）
                while page.hasMore {
                    page = try ObjectRepository.shared.listPage(host: host, dir: dir, offset: page.nextOffset, limit: 256, reverse: true)
                    let more = page.entries
                    DispatchQueue.main.async {
                        self.entries.append(contentsOf: more)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.loadError = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    private func requestThumbs(for page: [ObjectRepository.FtpEntry]) {
        guard let host = host, let guid = connection.camera?.guid else { return }
        let keys = page.filter { !$0.isDir }.map {
            ThumbStore.Key(cameraGuid: guid, path: $0.path)
        }
        ThumbStore.shared.requestSmall(host: host, keys: keys)
    }

    // MARK: 网格

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 2)], spacing: 2) {
                ForEach(entries) { entry in
                    cell(entry)
                }
            }
            .padding(2)
        }
    }

    private func cell(_ entry: ObjectRepository.FtpEntry) -> some View {
        let guid = connection.camera?.guid ?? ""
        return Group {
            if entry.isDir {
                Button { enterDir(entry) } label: {
                    VStack {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.tint)
                        Text(entry.name).font(.caption2).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 96)
                }
                .buttonStyle(.plain)
            } else {
                ThumbCell(entry: entry, cameraGuid: guid, host: host ?? "",
                          selected: selected.contains(entry.path)) {
                    if selectionMode {
                        toggleSelect(entry)
                    } else {
                        previewPath = entry
                    }
                }
                .onLongPressGesture {
                    selectionMode = true
                    toggleSelect(entry)
                }
            }
        }
    }

    private func toggleSelect(_ entry: ObjectRepository.FtpEntry) {
        if selected.contains(entry.path) {
            selected.remove(entry.path)
        } else {
            selected.insert(entry.path)
        }
        if selected.isEmpty { selectionMode = false }
    }

    private func toggleSelectAll() {
        let files = entries.filter { !$0.isDir }
        if selected.count == files.count {
            selected = []
            selectionMode = false
        } else {
            selected = Set(files.map { $0.path })
        }
    }

    private func exitSelection() {
        selected = []
        selectionMode = false
    }

    // MARK: 下载

    private func startDownload() {
        guard let guid = connection.camera?.guid else { return }
        let deviceDir = StorageSinks.deviceFolder(for: guid)
        let files = entries.filter { selected.contains($0.path) }
        TransferStore.shared.enqueue(cameraGuid: guid, deviceDir: deviceDir, entries: files)
        exitSelection()
    }
}

/// 缩略图格子：磁盘缓存 → 未命中则批量请求 → 点击预览（拉大预览）。
struct ThumbCell: View {
    let entry: ObjectRepository.FtpEntry
    let cameraGuid: String
    let host: String
    let selected: Bool
    let action: () -> Void

    @State private var image: UIImage?

    private var key: ThumbStore.Key { ThumbStore.Key(cameraGuid: cameraGuid, path: entry.path) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 96, height: 96)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.15))
                    .frame(width: 96, height: 96)
                    .overlay {
                        if entry.ext == "arw" || entry.ext == "raw" {
                            Image(systemName: "camera.aperture").foregroundStyle(.secondary)
                        } else {
                            Image(systemName: "photo").foregroundStyle(.secondary)
                        }
                    }
            }
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint, .white)
                    .padding(3)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onReceive(NotificationCenter.default.publisher(for: .alphasyncThumbUpdated)) { _ in
            if self.image == nil, let img = ThumbStore.shared.smallThumb(self.key) {
                self.image = img
            }
        }
        .onAppear {
            if let img = ThumbStore.shared.smallThumb(key) {
                image = img
            } else {
                ThumbStore.shared.requestSmall(host: host, keys: [key])
                // 稍后回看缓存（简化：延迟重试）
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if self.image == nil, let img = ThumbStore.shared.smallThumb(self.key) {
                        self.image = img
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    if self.image == nil, let img = ThumbStore.shared.smallThumb(self.key) {
                        self.image = img
                    }
                }
            }
        }
    }
}
