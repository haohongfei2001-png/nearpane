import AppKit
import Carbon.HIToolbox
import NearpaneCore
import Observation

/// Registers one chord with the system. No keyboard event tap or input-monitoring permission.
@MainActor @Observable public final class DesktopOverviewShortcut {
    public static let shared = DesktopOverviewShortcut()
    public private(set) var status = ""
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var id = UInt32(0)
    @ObservationIgnored public var show: (() -> Void)?
    private static let signature: OSType = 0x4E70534F

    static func systemReserves(_ modifiers: UInt32, in rows: [[String: Any]]) -> Bool {
        rows.contains {
            ($0["kHISymbolicHotKeyEnabled"] as? Bool) == true &&
            ($0["kHISymbolicHotKeyCode"] as? NSNumber)?.intValue == kVK_UpArrow &&
            ($0["kHISymbolicHotKeyModifiers"] as? NSNumber)?.uint32Value == modifiers
        }
    }

    public func configure(_ choice: OverviewShortcutChoice) {
        stop()
        guard show != nil, choice != .off else { return }
        let modifiers = UInt32(choice == .controlUp ? controlKey : controlKey | optionKey | cmdKey)
        var reserved: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&reserved) == noErr, let rows = reserved?.takeRetainedValue() as? [[String: Any]] else {
            status = "系统快捷键状态暂不可读，可以从 Nearpane 菜单打开。"; return
        }
        guard !Self.systemReserves(modifiers, in: rows) else {
            status = "这个快捷键已分配给 macOS。请在「系统设置 → 键盘 → 键盘快捷键」释放它，再点重新注册。"; return
        }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &key) == noErr else { return OSStatus(eventNotHandledErr) }
            return MainActor.assumeIsolated {
                let shortcut = Unmanaged<DesktopOverviewShortcut>.fromOpaque(context).takeUnretainedValue()
                guard key.signature == DesktopOverviewShortcut.signature, key.id == shortcut.id, shortcut.hotKey != nil else {
                    return OSStatus(eventNotHandledErr)
                }
                shortcut.show?()
                return noErr
            }
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        id &+= 1
        guard installed == noErr, RegisterEventHotKey(UInt32(kVK_UpArrow), modifiers,
            EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(),
            UInt32(kEventHotKeyExclusive), &hotKey) == noErr else {
            stop(); status = "快捷键未注册，可以从 Nearpane 菜单打开。"; return
        }
        status = choice == .controlUp ? "⌃↑ 已连接到 Nearpane。" : "⌃⌥⌘↑ 已连接到 Nearpane。"
    }

    public func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
        status = ""
    }
}
