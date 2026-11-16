import SwiftUI
import RiftletCore

private typealias ViewState<T> = State<T>

@MainActor public struct ScreenshotArchiveView: View {
    private let module: TrayModule
    private let openSettings: (() -> Void)?

    public init(module: TrayModule, openSettings: (() -> Void)? = nil) {
        self.module = module
        self.openSettings = openSettings
    }

    public var body: some View {
        if let session = module.archiveSession {
            ArchiveBrowser(module: module, session: session)
                .id(session)
        } else if module.connecting {
            ProgressView("正在连接截图资料库…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label(module.active ? "截图资料库已断开" : "截图模块已停用", systemImage: "photo.stack")
            } description: {
                if let issue = module.issue { Text(issue) }
            } actions: {
                if let openSettings { Button("截图设置", action: openSettings) }
            }
        }
    }
}

@MainActor private struct ArchiveBrowser: View {
    let module: TrayModule
    let session: UUID
    @ViewState private var pageNumber = 0
    @ViewState private var page: ScreenshotArchivePage?
    @ViewState private var selected: UUID?
    @ViewState private var failed = false
    @ViewState private var retry = 0

    var body: some View {
        Group {
            if failed {
                ContentUnavailableView {
                    Label("暂时无法读取截图档案", systemImage: "photo.badge.exclamationmark")
                } actions: { Button("重新读取") { retry += 1 } }
            } else if let page {
                if let entry = page.entries.first(where: { $0.id == selected }) {
                    detail(entry)
                } else if page.entries.isEmpty {
                    ContentUnavailableView("还没有截图", systemImage: "photo.stack",
                                           description: Text("收录到 Nearpane 的截图会显示在这里。"))
                } else {
                    VStack(spacing: 8) {
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 142), spacing: 12)],
                                      alignment: .leading, spacing: 16) {
                                ForEach(page.entries) { entry in
                                    Button { selected = entry.id } label: {
                                        VStack(alignment: .leading, spacing: 5) {
                                            ArchiveImage(module: module, session: session, entry: entry, pixels: 350)
                                                .frame(height: 96)
                                            Text("截图 \(entry.record.sequence)").font(.headline)
                                            Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                                .font(.caption).foregroundStyle(.secondary)
                                            Text(entry.attachment ?? entry.visibility)
                                                .font(.caption).foregroundStyle(.secondary)
                                        }.contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("archive-capture-\(entry.id.uuidString)")
                                }
                            }.padding(4)
                        }
                        if pageNumber > 0 || page.hasOlder {
                            HStack {
                                Button("上一页") { move(-1) }.disabled(pageNumber == 0)
                                Spacer()
                                Text("第 \(pageNumber + 1) 页").font(.caption)
                                Spacer()
                                Button("下一页") { move(1) }.disabled(!page.hasOlder)
                            }
                        }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: LoadKey(page: pageNumber, revision: module.archiveRevision, retry: retry)) {
            do {
                let next = try await module.archivePage(offset: pageNumber * ScreenshotArchivePage.size, session: session)
                try Task.checkCancellation()
                page = next
                if !next.entries.contains(where: { $0.id == selected }) { selected = nil }
                failed = false
            } catch {
                if !Task.isCancelled { failed = true; page = nil }
            }
        }
    }

    private struct LoadKey: Equatable {
        let page: Int
        let revision: UInt64
        let retry: Int
    }

    private func move(_ direction: Int) {
        page = nil
        pageNumber += direction
    }

    private func detail(_ entry: ScreenshotArchiveEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { selected = nil } label: { Label("返回截图档案", systemImage: "chevron.left") }
            ArchiveImage(module: module, session: session, entry: entry, pixels: 1536)
                .frame(maxHeight: .infinity)
            Text("截图 \(entry.record.sequence)").font(.headline)
            Text(entry.date.formatted(date: .long, time: .standard))
            Text("\(entry.record.image.pixelWidth) × \(entry.record.image.pixelHeight) px · \(ByteCountFormatter.string(fromByteCount: entry.record.image.byteCount, countStyle: .file))")
            Text([entry.visibility, entry.attachment].compactMap { $0 }.joined(separator: " · "))
        }.font(.callout)
    }
}

@MainActor private struct ArchiveImage: View {
    let module: TrayModule
    let session: UUID
    let entry: ScreenshotArchiveEntry
    let pixels: Int
    @ViewState private var image: CGImage?
    @ViewState private var loaded = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.55))
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else if loaded {
                Label("图像不可用", systemImage: "photo").foregroundStyle(.secondary).font(.caption)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: entry.id) {
            let rendered = await module.archiveImage(entry.record.image, pixels: pixels, session: session)
            guard !Task.isCancelled else { return }
            image = rendered
            loaded = true
        }
    }
}
