#if canImport(SaytileKit) && canImport(RiftletCore)
import AppKit
import SwiftUI
import RiftletCapture
import RiftletCore

/// Only used by the executable-bound native review session. The four windows contain generated
/// fixture content, have no key/main eligibility and are the reader's entire allowlist.
@MainActor final class SharedVoiceReviewScene {
    private final class PassiveWindow: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    let windows: [NSWindow]

    init(screen: NSScreen) {
        let area = screen.visibleFrame
        let width = min(560, area.width * 0.45), height = min(340, area.height * 0.46)
        self.windows = ReviewDocument.allCases.enumerated().map { index, sample in
            let window = PassiveWindow(contentRect: .init(x: 0, y: 0, width: width, height: height),
                                       styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = true
            window.appearance = NSAppearance(named: .aqua)
            window.title = sample.title
            window.contentView = NSHostingView(rootView: ReviewDocumentView(document: sample))
            window.setFrameOrigin(.init(x: area.minX + 24 + CGFloat(index) * 30,
                                        y: area.minY + 36 + CGFloat(index) * 24))
            return window
        }
        // Match the reference's document / revision / plan / editor progression.
        // orderBack keeps these four synthetic documents below the user's foreground windows.
        for document in [ReviewDocument.article, .notes, .plan, .code] {
            if let index = ReviewDocument.allCases.firstIndex(of: document) {
                windows[index].orderBack(nil)
                windows[index].displayIfNeeded()
            }
        }
    }

    func importTray(into root: URL) async throws {
        let captureDirectory = root.appendingPathComponent("captures", isDirectory: true)
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        // This fresh, executable-bound acceptance library has no host owner until connect().
        let queue = try QueueStore(databaseURL: root.appendingPathComponent("queue.sqlite"))
        let importer = PrivateAssetImporter(privateRoot: root, store: queue)
        for (index, window) in windows.prefix(3).enumerated().reversed() {
            guard let content = window.contentView, let view = content.superview else {
                throw CocoaError(.validationMissingMandatoryProperty)
            }
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw CocoaError(.fileWriteUnknown)
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let image = rep.representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let source = captureDirectory.appendingPathComponent("review-window-\(index).png")
            try image.write(to: source, options: .withoutOverwriting)
            _ = try await importer.importBuiltInScreenshot(original: source, outputDirectory: captureDirectory)
        }
    }

    func close() {
        for window in windows { window.orderOut(nil); window.close() }
    }
}

private enum ReviewDocument: CaseIterable {
    case article, code, plan, notes
    var title: String {
        switch self {
        case .article: "设计系统的实践与思考"
        case .code: "Workspace · WindowLayout.swift"
        case .plan: "项目规划"
        case .notes: "版本更新"
        }
    }
}

private struct ReviewDocumentView: View {
    let document: ReviewDocument

    var body: some View {
        switch document {
        case .article:
            VStack(alignment: .leading, spacing: 12) {
                HStack { Image(systemName: "lock.fill"); Text("example.test / design-system") }
                    .font(.caption).foregroundStyle(.secondary)
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(colors: [.indigo, Color(red: 0.69, green: 0.72, blue: 1), .blue],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(height: 82)
                Text(document.title).font(.title.bold())
                Text("将布局、字体和控件整理成一致的界面规范。")
                Divider()
                Text("一、建立基础").font(.headline)
                Text("先检查常用文字、控件间距和层级，再讨论细节。")
                Spacer()
            }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(Color.white)
        case .plan:
            VStack(alignment: .leading, spacing: 14) {
                Text(document.title).font(.largeTitle.bold())
                ForEach(["确定目标范围", "输出界面规范", "验证连续输入", "完成产品复核"], id: \.self) { label in
                    Label(label, systemImage: label == "确定目标范围" ? "checkmark.square.fill" : "square")
                        .font(.title3)
                }
                Spacer()
            }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(Color.white)
        case .code:
            HStack(alignment: .top, spacing: 17) {
                VStack(alignment: .leading, spacing: 11) {
                    Text("EXPLORER").bold()
                    ForEach(["Sources", "  Layout.swift", "  Preview.swift", "  Scene.swift"], id: \.self) { Text($0) }
                }.foregroundStyle(.white.opacity(0.7)).padding(12)
                    .frame(maxHeight: .infinity, alignment: .top).background(.white.opacity(0.06))
                VStack(alignment: .leading, spacing: 9) {
                    Text("import SwiftUI").foregroundStyle(.purple)
                    Text("struct LayoutGuide: View {").foregroundStyle(.cyan)
                    Text("    let title: String").foregroundStyle(.orange)
                    Text("    var body: some View {")
                    Text("        Text(title)").foregroundStyle(.mint)
                    Text("    }"); Text("}")
                }.padding(.top, 16)
                Spacer(minLength: 0)
            }.font(.system(size: 13, design: .monospaced)).foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(Color(red: 0.1, green: 0.11, blue: 0.13))
        case .notes:
            VStack(alignment: .leading, spacing: 13) {
                Text(document.title).font(.largeTitle.bold())
                Text("组件优化和交互调整").font(.title3)
                Divider()
                Text("保留稳定前缀，及时更新识别中的文字。")
                Text("三个应用窗口使用独立的本地测试资料。")
                Spacer()
            }.padding(26).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(Color.white)
        }
    }
}
#endif
