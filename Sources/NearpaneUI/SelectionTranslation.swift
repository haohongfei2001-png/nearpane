import AppKit
import ApplicationServices
import NaturalLanguage
import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// macOS supplies the selection through Services. AX is read only after that explicit request.
@MainActor final class SelectionTranslation: NSObject {
    private let notebook: SidebarNotebook
    private var bubble: NSPanel?
    private var pending: Task<Void, Never>?
    init(notebook: SidebarNotebook) { self.notebook = notebook }

    @objc func translateNearpaneSelection(_ pasteboard: NSPasteboard, userData: String?,
                                          error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let selection = pasteboard.string(forType: .string), !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let anchor = Self.selectionBounds(for: selection) else {
            error.pointee = "无法定位原选区。请核对 Nearpane 的辅助功能权限，再选择文字。" as NSString
            return
        }
        pending?.cancel()
        show("正在查询…", at: anchor)
        pending = Task {
            #if canImport(Translation)
            if #available(macOS 26, *) {
                let language = NLLanguageRecognizer.dominantLanguage(for: selection)?.rawValue ?? "en"
                let target = language.hasPrefix("zh") ? "en" : "zh-Hans"
                let from = Locale.Language(identifier: language), to = Locale.Language(identifier: target)
                do {
                    guard await LanguageAvailability().status(from: from, to: to) == .installed else {
                        throw TranslationIssue.language
                    }
                    let answer = try await TranslationSession(installedSource: from, target: to).translate(selection)
                    try Task.checkCancellation()
                    guard let live = Self.selectionBounds(for: selection), live.intersects(anchor) else { close(); return }
                    let saved = notebook.edit { data in
                        data.words.removeAll { $0.source == selection && $0.language == target }
                        data.words.insert(.init(source: selection, translation: answer.targetText, language: target), at: 0)
                    }
                    show(answer.targetText + (saved ? "" : "\n单词本保存失败"), at: live)
                } catch {
                    if !Task.isCancelled { show(error.localizedDescription, at: anchor) }
                }
            } else { show("当前系统不支持本地翻译。", at: anchor) }
            #else
            show("当前系统不支持本地翻译。", at: anchor)
            #endif
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            close()
        }
    }

    private enum TranslationIssue: LocalizedError {
        case language
        var errorDescription: String? { "请先在 macOS 翻译设置中下载所需语言。" }
    }

    private static func selectionBounds(for text: String) -> NSRect? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.18)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let element = raw as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.18)
        var selected: CFTypeRef?, range: CFTypeRef?, bounds: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success,
              selected as? String == text,
              AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success, let range,
              AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds) == .success,
              let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect), !rect.isEmpty, let primary = NSScreen.screens.first else { return nil }
        return NSRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    private func show(_ text: String, at rect: NSRect) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) else { close(); return }
        let view = NSHostingView(rootView: Text(text).font(.system(size: 14)).padding(10)
            .frame(maxWidth: 280).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)))
        let size = view.fittingSize
        let visible = screen.visibleFrame
        let x = min(max(rect.minX, visible.minX), visible.maxX - size.width)
        let below = rect.minY - size.height - 5
        let y = below >= visible.minY ? below : min(rect.maxY + 5, visible.maxY - size.height)
        let panel = bubble ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.hidesOnDeactivate = false; panel.level = .popUpMenu; panel.ignoresMouseEvents = true
        panel.contentView = view
        panel.setFrame(NSRect(origin: CGPoint(x: x, y: y), size: size), display: true)
        bubble = panel
        panel.orderFrontRegardless()
    }

    func close() { bubble?.orderOut(nil); bubble = nil }
}
