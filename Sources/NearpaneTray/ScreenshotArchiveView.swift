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
        content
            .task(id: module.active) { await module.openArchive() }
            .onDisappear { module.closeArchive() }
    }

    @ViewBuilder private var content: some View {
        if let session = module.archiveSession {
            ArchiveBrowser(module: module, session: session)
                .id(session)
        } else if module.connecting || module.archiveOpening {
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
    @ViewState private var copyNotice: String?

    var body: some View {
        Group {
            if failed {
                ContentUnavailableView {
                    Label("暂时无法读取截图档案", systemImage: "photo.badge.exclamationmark")
                } actions: { Button("重新读取") { retry += 1 } }
            } else if let page {
                if page.entries.isEmpty {
                    ContentUnavailableView("还没有截图", systemImage: "photo.stack",
                                           description: Text("收录到 Nearpane 的截图会显示在这里。"))
                } else {
                    GeometryReader { geometry in
                        if let entry = page.entries.first(where: { $0.id == selected }) {
                            // Keep the library in sight when two 140-point cards and
                            // a readable inspector fit. Narrow settings show one pane.
                            if geometry.size.width >= 600 {
                                HStack(spacing: 16) {
                                    library(page)
                                    Divider()
                                    detail(entry)
                                        .frame(width: min(300, geometry.size.width * 0.40))
                                }
                            } else {
                                detail(entry)
                            }
                        } else {
                            library(page)
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

    private func library(_ page: ScreenshotArchivePage) -> some View {
        VStack(spacing: 8) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16)],
                          alignment: .leading, spacing: 14) {
                    ForEach(page.dateSections(), id: \.period) { section in
                        Section {
                            ForEach(section.entries) { entry in
                                Button { selected = entry.id } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        ArchiveImage(module: module, session: session, entry: entry,
                                                     pixels: 480, selected: selected == entry.id)
                                            .frame(height: 108)
                                            .padding(.bottom, 2)
                                        Text(entry.date, format: .dateTime.hour().minute())
                                            .monospacedDigit()
                                        Text(entry.attachment ?? entry.visibility)
                                    }
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(entry.date.formatted(date: .complete, time: .standard))
                                .accessibilityLabel("截图 \(entry.record.sequence)，\(entry.date.formatted())，\(entry.attachment ?? entry.visibility)")
                                .accessibilityIdentifier("archive-capture-\(entry.id.uuidString)")
                            }
                        } header: {
                            Text(section.period.title).font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary).padding(.top, 6)
                        }
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

    private func move(_ direction: Int) {
        page = nil
        pageNumber += direction
    }

    private func detail(_ entry: ScreenshotArchiveEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { selected = nil } label: { Label("返回截图仓库", systemImage: "chevron.left") }
                Spacer()
                Button {
                    Task {
                        copyNotice = await module.copyArchiveImage(entry.record.image, session: session) ? "已复制原图" : "原图暂时不可用"
                    }
                } label: { Label("复制", systemImage: "doc.on.doc") }
                .accessibilityIdentifier("screenshot-library-copy")
            }
            ArchiveImage(module: module, session: session, entry: entry, pixels: 1536)
                .frame(maxHeight: .infinity)
            if let copyNotice { Text(copyNotice).font(.caption).foregroundStyle(.secondary) }
            Text("截图 \(entry.record.sequence)").font(.title3.weight(.semibold))
            Text(entry.date.formatted(date: .long, time: .standard)).monospacedDigit()
            Text("\(entry.record.image.pixelWidth) × \(entry.record.image.pixelHeight) px · \(ByteCountFormatter.string(fromByteCount: entry.record.image.byteCount, countStyle: .file))")
                .foregroundStyle(.secondary)
            Text([entry.visibility, entry.attachment].compactMap { $0 }.joined(separator: " · "))
        }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor private struct ArchiveImage: View {
    let module: TrayModule
    let session: UUID
    let entry: ScreenshotArchiveEntry
    let pixels: Int
    var selected = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @ViewState private var image: CGImage?
    @ViewState private var loaded = false

    var body: some View {
        ZStack {
            let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
            shape.fill(Color(nsColor: .controlBackgroundColor))
                .overlay { shape.fill(Color.primary.opacity(colorScheme == .dark ? 0.035 : 0.018)) }
                .overlay {
                    shape.strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary.opacity(contrast == .increased ? 0.55 : 0.15)),
                                       lineWidth: selected || contrast == .increased ? 2 : 1)
                }
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit().padding(10)
            } else if loaded {
                Label("图像不可用", systemImage: "photo").foregroundStyle(.secondary).font(.caption)
            }
        }
        .onDrag { module.archiveDragProvider(entry.record.image, session: session) }
        .task(id: entry.record.image) {
            loaded = false
            image = nil
            let rendered = await module.archiveImage(entry.record.image, pixels: pixels, session: session)
            guard !Task.isCancelled else { return }
            image = rendered
            loaded = true
        }
    }
}
