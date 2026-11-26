import AppKit
import SwiftUI

/// NSMenu lifecycle explicitly holds the hover surface open while the pointer is in the menu.
struct LyricSongMenu: NSViewRepresentable {
    @ObservedObject var model: LyricAppModel
    let dark: Bool
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.open(_:)))
        button.isBordered = false
        button.bezelStyle = .inline
        button.setButtonType(.momentaryPushIn)
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.alignment = .left
        button.cell?.lineBreakMode = .byTruncatingTail
        button.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 7, weight: .semibold))
        button.imagePosition = .imageTrailing
        button.imageScaling = .scaleProportionallyDown
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        button.title = model.title
        button.isEnabled = model.snapshot.selection != nil
        button.contentTintColor = LyricPalette.primary(dark: dark)
        button.setAccessibilityLabel("歌曲菜单，\(model.title)")
        button.toolTip = "选择歌词版本、调整时间或导入歌词"
    }
    @MainActor
    final class Coordinator: NSObject, NSMenuDelegate {
        let model: LyricAppModel
        init(model: LyricAppModel) { self.model = model }
        @objc func open(_ sender: NSButton) {
            let menu = NSMenu()
            menu.delegate = self
            menu.autoenablesItems = false
            add("完整歌词", "full", to: menu, enabled: model.document != nil)
            menu.addItem(.separator())
            add("选择歌词版本…", "versions", to: menu)
            add("时间校准…", "timing", to: menu, enabled: model.document != nil)
            add("导入歌词…", "import", to: menu)
            add("查看来源…", "source", to: menu, enabled: model.document != nil)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 3), in: sender)
        }
        private func add(_ title: String, _ key: String, to menu: NSMenu, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: #selector(invoke(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = key; item.isEnabled = enabled
            menu.addItem(item)
        }
        func menuWillOpen(_ menu: NSMenu) { model.songMenuIsOpen = true; model.setControlsVisible(true) }
        func menuDidClose(_ menu: NSMenu) { model.songMenuIsOpen = false }
        @objc private func invoke(_ item: NSMenuItem) {
            switch item.representedObject as? String {
            case "full": model.show(.fullLyrics)
            case "versions": model.show(.candidates)
            case "timing": model.show(.adjustment)
            case "import": model.importLyrics()
            case "source": model.show(.source)
            default: break
            }
        }
    }
}
