import AppKit
import Carbon.HIToolbox
import NearpaneCore
import Observation

/// One global shortcut follows the dispatcher that can actually open the window overview.
@MainActor @Observable public final class DesktopOverviewShortcut {
    public static let shared = DesktopOverviewShortcut()
    public private(set) var status = ""
    public var registered: Bool { release != nil }

    enum Reservation { case available, system, unknown }
    typealias Register = @MainActor (OverviewShortcutChoice, UInt32, @escaping (UInt32) -> Bool) -> (() -> Void)?
    @ObservationIgnored private let reservation: @MainActor (OverviewShortcutChoice) -> Reservation
    @ObservationIgnored private let register: Register
    @ObservationIgnored private var choice: OverviewShortcutChoice = .off
    @ObservationIgnored private var attempted: OverviewShortcutChoice?
    @ObservationIgnored private var release: (() -> Void)?
    @ObservationIgnored private var generation: UInt32 = 0
    @ObservationIgnored private var eligible: (() -> Bool)?
    @ObservationIgnored private var open: (() -> Bool)?

    init(reservation: @escaping @MainActor (OverviewShortcutChoice) -> Reservation = CarbonOverviewKey.reservation,
         register: @escaping Register = CarbonOverviewKey.register) {
        self.reservation = reservation
        self.register = register
    }

    static func systemReserves(_ modifiers: UInt32, in rows: [[String: Any]]) -> Bool {
        rows.contains { row in
            guard row["kHISymbolicHotKeyEnabled"] as? Bool == true,
                  (row["kHISymbolicHotKeyCode"] as? NSNumber)?.intValue == kVK_UpArrow,
                  let flags = (row["kHISymbolicHotKeyModifiers"] as? NSNumber)?.uint32Value else { return false }
            return flags & ~UInt32(kEventKeyModifierFnMask) == modifiers
        }
    }

    public func start(_ choice: OverviewShortcutChoice, eligible: @escaping () -> Bool, open: @escaping () -> Bool) {
        stop()
        self.eligible = eligible
        self.open = open
        configure(choice)
    }

    public func configure(_ choice: OverviewShortcutChoice) {
        if self.choice != choice { relinquish() }
        self.choice = choice
        refreshOwnership(recheckReservation: true)
    }

    public func refreshOwnership(recheckReservation: Bool = false) {
        guard let eligible else { return }
        guard choice != .off, eligible() else {
            relinquish()
            let message = choice == .off ? "" : "窗口总览当前不可用，快捷键已释放。"
            if status != message { status = message }
            return
        }
        if attempted == choice && !recheckReservation { return }
        switch reservation(choice) {
        case .system:
            relinquish()
            status = "这个快捷键由 macOS 使用。"
        case .unknown:
            relinquish()
            status = "系统快捷键状态暂不可读，可以从 Nearpane 菜单打开总览。"
        case .available:
            if release == nil {
                generation &+= 1
                release = register(choice, generation) { [weak self] id in self?.pressed(id) == true }
            }
            if release == nil { status = "快捷键未注册，可以从 Nearpane 菜单打开总览。" }
            else { status = choice == .controlUp ? "⌃↑ 已连接到 Nearpane。" : "⌃⌥⌘↑ 已连接到 Nearpane。" }
        }
        attempted = choice
    }

    private func pressed(_ id: UInt32) -> Bool {
        guard release != nil, id == generation else { return false }
        refreshOwnership(recheckReservation: true)
        guard release != nil, id == generation else { return false }
        return open?() == true
    }

    private func relinquish() {
        let dispose = release
        release = nil
        attempted = nil
        dispose?()
    }

    public func stop() {
        relinquish()
        eligible = nil
        open = nil
        choice = .off
        status = ""
    }
}

@MainActor private final class CarbonOverviewKey {
    private static let signature: OSType = 0x4E70534F
    private var key: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let receive: (UInt32) -> Bool

    init(receive: @escaping (UInt32) -> Bool) { self.receive = receive }

    private static func modifiers(_ choice: OverviewShortcutChoice) -> UInt32 {
        UInt32(choice == .controlUp ? controlKey : controlKey | optionKey | cmdKey)
    }

    static func reservation(_ choice: OverviewShortcutChoice) -> DesktopOverviewShortcut.Reservation {
        var raw: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&raw) == noErr, let rows = raw?.takeRetainedValue() as? [[String: Any]] else { return .unknown }
        return DesktopOverviewShortcut.systemReserves(modifiers(choice), in: rows) ? .system : .available
    }

    static func register(_ choice: OverviewShortcutChoice, id: UInt32, receive: @escaping (UInt32) -> Bool) -> (() -> Void)? {
        let holder = CarbonOverviewKey(receive: receive)
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &key) == noErr else { return OSStatus(eventNotHandledErr) }
            return MainActor.assumeIsolated {
                let holder = Unmanaged<CarbonOverviewKey>.fromOpaque(context).takeUnretainedValue()
                return key.signature == CarbonOverviewKey.signature && holder.receive(key.id) ? noErr : OSStatus(eventNotHandledErr)
            }
        }, 1, &spec, Unmanaged.passUnretained(holder).toOpaque(), &holder.handler)
        guard installed == noErr, RegisterEventHotKey(UInt32(kVK_UpArrow), modifiers(choice),
            EventHotKeyID(signature: signature, id: id), GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &holder.key) == noErr else {
            holder.remove()
            return nil
        }
        return { holder.remove() }
    }

    private func remove() {
        if let key { UnregisterEventHotKey(key); self.key = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }
}
