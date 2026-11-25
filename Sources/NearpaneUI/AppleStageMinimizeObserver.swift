import AppKit
import ApplicationServices
import CNearpaneWindowEngine
import CReadOnlySpaces
import NearpaneCore

/// At most one live AX read per window. A later notice supersedes an
/// unfinished read. Duplicate final states are suppressed by the Rust decision.
struct AppleMinimizeReadOrder {
    enum Result: Equatable { case idle, refresh, readLatest(UInt32) }
    private var active: Set<DesktopWindowKey> = []
    private var next: [DesktopWindowKey: UInt32] = [:]
    private var last: [DesktopWindowKey: UInt32] = [:]

    mutating func begin(_ key: DesktopWindowKey, event: UInt32) -> UInt32? {
        guard active.insert(key).inserted else { next[key] = event; return nil }
        return last[key] ?? UInt32(NP_APPLE_MINIMIZE_UNKNOWN)
    }

    mutating func finish(_ key: DesktopWindowKey, confirmed: UInt32?) -> Result {
        guard active.remove(key) != nil else { return .idle }
        if let newer = next.removeValue(forKey: key) { return .readLatest(newer) }
        guard let confirmed else { return .idle }
        last[key] = confirmed
        return .refresh
    }

    mutating func remove(_ key: DesktopWindowKey) {
        active.remove(key); next.removeValue(forKey: key); last.removeValue(forKey: key)
    }
}

/// Watches only a native mirror's admitted windows. The callback invalidates the
/// mirror; Apple's window arrangement must still be freshly read by the caller.
@MainActor final class AppleStageMinimizeObserver {
    typealias Changed = @MainActor () -> Void
    private let reads = DispatchQueue(label: "Nearpane.AppleStage.minimize", qos: .utility)
    private var desired: [pid_t: Set<DesktopWindowKey>] = [:]
    private var registrations: [pid_t: Registration] = [:]
    private struct Pending { let ticket: UUID, keys: Set<DesktopWindowKey>, work: DispatchWorkItem }
    private var pending: [pid_t: Pending] = [:]
    private var retryAfter: [pid_t: TimeInterval] = [:]
    private var order = AppleMinimizeReadOrder()
    private var termination: NSObjectProtocol?
    private var changed: Changed?
    private let observesGeometry: Bool

    init(observesGeometry: Bool = false) { self.observesGeometry = observesGeometry }

    // AX sources run on the main run loop. Route by the delivering observer so
    // a queued notification can never dereference a released refcon.
    // The callback is synchronously delivered by the main CFRunLoop. No AX
    // reference from this envelope escapes that callback onto another queue.
    private struct Notice: @unchecked Sendable { let observer: AXObserver, element: AXUIElement, name: String }
    private final class Destination { weak var value: AppleStageMinimizeObserver? }
    private static var destinations: [ObjectIdentifier: Destination] = [:]

    // Built by the serial read queue, then immutable. AX reads and registrations
    // stay off the UI thread even when an application stops responding.
    private final class Registration: @unchecked Sendable {
        let observer: AXObserver, keys: Set<DesktopWindowKey>
        let elements: [DesktopWindowKey: AXUIElement]
        init(_ observer: AXObserver, _ keys: Set<DesktopWindowKey>, _ elements: [DesktopWindowKey: AXUIElement]) {
            self.observer = observer; self.keys = keys; self.elements = elements
        }

    }

    isolated deinit { stop() }

    nonisolated static func admitted(_ targets: [DesktopWindowKey], ownPID: pid_t) -> [pid_t: Set<DesktopWindowKey>] {
        var result: [pid_t: Set<DesktopWindowKey>] = [:], count = 0
        // Keep the caller's priority. An over-budget or contradictory inventory
        // still has the regular mirror read and never gains window write rights.
        var conflicted: Set<pid_t> = []
        for key in targets.prefix(256) where key.pid > 1 && key.pid != ownPID && key.number > 0 && key.birth > 0 && !conflicted.contains(key.pid) {
            if let first = result[key.pid]?.first, first.birth != key.birth {
                count -= result.removeValue(forKey: key.pid)?.count ?? 0
                conflicted.insert(key.pid)
            } else if count < 128 && (result[key.pid] != nil || result.count < 24), result[key.pid, default: []].insert(key).inserted {
                count += 1
            }
        }
        return result
    }

    func update(targets: [DesktopWindowKey], changed: @escaping Changed) {
        guard !targets.isEmpty, AXIsProcessTrusted() else { stop(); return }
        desired = Self.admitted(targets, ownPID: getpid())
        self.changed = changed
        if termination == nil {
            termination = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil, queue: .main) { [weak self] notice in
                guard let app = notice.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated { self?.terminated(app.processIdentifier) }
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        for (pid, active) in registrations {
            let changedScope = active.keys != desired[pid]
            let partial = active.elements.count != active.keys.count && now >= (retryAfter[pid] ?? 0)
            if changedScope || partial { detach(pid); retryAfter.removeValue(forKey: pid) }
        }
        for (pid, item) in pending where item.keys != desired[pid] {
            item.work.cancel(); pending.removeValue(forKey: pid)
        }
        retryAfter = retryAfter.filter { desired[$0.key] != nil }
        for (pid, keys) in desired where registrations[pid] == nil && pending[pid] == nil && now >= (retryAfter[pid] ?? 0) {
            let ticket = UUID()
            // DispatchWorkItem's unannotated block otherwise inherits MainActor;
            // libdispatch runs this registration on the serial AX queue.
            let observeGeometry = observesGeometry
            let work = DispatchWorkItem { @Sendable [weak self] in
                let registration = Self.prepare(pid, keys: keys, observeGeometry: observeGeometry)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.pending[pid]?.ticket == ticket else { return }
                    self.pending.removeValue(forKey: pid)
                    guard self.desired[pid] == keys else { return }
                    guard let registration else { self.retryAfter[pid] = ProcessInfo.processInfo.systemUptime + 30; return }
                    self.registrations[pid] = registration
                    if registration.elements.count < keys.count { self.retryAfter[pid] = ProcessInfo.processInfo.systemUptime + 30 }
                    let destination = Destination(); destination.value = self
                    Self.destinations[ObjectIdentifier(registration.observer)] = destination
                    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(registration.observer), .commonModes)
                }
            }
            pending[pid] = Pending(ticket: ticket, keys: keys, work: work)
            reads.async(execute: work)
        }
    }

    /// An isolated fixture waits for each admitted window's native registration.
    func observes(_ key: DesktopWindowKey) -> Bool { registrations[key.pid]?.elements[key] != nil }

    func stop() {
        for item in pending.values { item.work.cancel() }
        desired.removeAll(); pending.removeAll(); retryAfter.removeAll(); changed = nil
        order = AppleMinimizeReadOrder()
        for pid in registrations.keys { detach(pid) }
        if let termination { NSWorkspace.shared.notificationCenter.removeObserver(termination); self.termination = nil }
    }

    private func terminated(_ pid: pid_t) {
        guard let keys = desired[pid] else { return }
        // A queued termination of a former owner may arrive after pid reuse.
        if let current = NSRunningApplication(processIdentifier: pid), !current.isTerminated,
           (try? OrdinaryProcessImage.read(pid).launch) == keys.first?.birth { return }
        desired.removeValue(forKey: pid)
        pending.removeValue(forKey: pid)?.work.cancel(); retryAfter.removeValue(forKey: pid); detach(pid); changed?()
    }

    private func detach(_ pid: pid_t) {
        guard let registration = registrations.removeValue(forKey: pid) else { return }
        for key in registration.keys { order.remove(key) }
        Self.destinations.removeValue(forKey: ObjectIdentifier(registration.observer))
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(registration.observer), .commonModes)
    }

    private nonisolated static func prepare(_ pid: pid_t, keys: Set<DesktopWindowKey>, observeGeometry: Bool) -> Registration? {
        guard let birth = keys.first?.birth, let image = try? OrdinaryProcessImage.read(pid), image.launch == birth,
              let owner = NSRunningApplication(processIdentifier: pid), !owner.isTerminated, owner.activationPolicy == .regular else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var list: CFArray?, length: CFIndex = 0
        guard AXUIElementSetMessagingTimeout(app, 0.08) == .success,
              AXUIElementGetAttributeValueCount(app, kAXWindowsAttribute as CFString, &length) == .success, length > 0,
              AXUIElementCopyAttributeValues(app, kAXWindowsAttribute as CFString, 0, min(128, length), &list) == .success,
              let windows = list as? [AXUIElement] else { return nil }
        var observer: AXObserver?
        let callback: AXObserverCallback = { observer, element, event, _ in
            let notice = Notice(observer: observer, element: element, name: event as String)
            MainActor.assumeIsolated {
                AppleStageMinimizeObserver.destinations[ObjectIdentifier(notice.observer)]?.value?.receive(notice.observer, notice.element, notice.name)
            }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return nil }
        var elements: [DesktopWindowKey: AXUIElement] = [:], ambiguous: Set<DesktopWindowKey> = []
        let deadline = ProcessInfo.processInfo.systemUptime + 0.35
        for win in windows {
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            guard AXUIElementSetMessagingTimeout(win, 0.06) == .success else { continue }
            let key = DesktopWindowKey(pid: pid, birth: birth, number: windowNumber(win))
            guard keys.contains(key), !ambiguous.contains(key) else { continue }
            if elements[key] != nil { elements.removeValue(forKey: key); ambiguous.insert(key); continue }
            elements[key] = win
        }
        elements = elements.filter { _, element in
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            let mini = AXObserverAddNotification(observer, element, kAXWindowMiniaturizedNotification as CFString, nil)
            let restore = AXObserverAddNotification(observer, element, kAXWindowDeminiaturizedNotification as CFString, nil)
            var subscribed = mini == .success || restore == .success
            if observeGeometry {
                let move = AXObserverAddNotification(observer, element, kAXWindowMovedNotification as CFString, nil)
                let resize = AXObserverAddNotification(observer, element, kAXWindowResizedNotification as CFString, nil)
                subscribed = subscribed || move == .success || resize == .success
            }
            guard subscribed else { return false }
            _ = AXObserverAddNotification(observer, element, kAXUIElementDestroyedNotification as CFString, nil)
            return true
        }
        guard !elements.isEmpty, (try? OrdinaryProcessImage.read(pid)) == image else { return nil }
        if observeGeometry {
            // A new document or a focus change inside the same app need not activate the app.
            // These notices wake the catalog. Only its independent window read can add a member.
            for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] {
                _ = AXObserverAddNotification(observer, app, name as CFString, nil)
            }
        }
        return Registration(observer, keys, elements)
    }

    private nonisolated static func windowNumber(_ element: AXUIElement) -> CGWindowID {
        let number = NPReadAXWindowNumber(element)
        if number != 0 { return number }
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXWindowNumber" as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == CFNumberGetTypeID(), let value = raw as? NSNumber else { return 0 }
        return UInt32(exactly: value.int64Value) ?? 0
    }

    private func receive(_ observer: AXObserver, _ element: AXUIElement, _ event: String) {
        guard let registration = registrations.values.first(where: { $0.observer === observer }) else { return }
        if event == kAXWindowCreatedNotification || event == kAXFocusedWindowChangedNotification {
            guard observesGeometry, let enrolled = registration.keys.first else { return }
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success, pid == enrolled.pid,
                  (try? OrdinaryProcessImage.read(pid).launch) == enrolled.birth else { return }
            changed?()
            return
        }
        guard let (key, _) = registration.elements.first(where: { CFEqual($0.value, element) }),
              desired[key.pid]?.contains(key) == true else { return }
        if event == kAXUIElementDestroyedNotification {
            // A destroyed element need not answer any further AX reads. Drop
            // its subscription and ask the independent mirror for the survivors.
            detach(key.pid); changed?(); return
        }
        let kind: UInt32
        switch event {
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            // macOS sends these notifications at the end of a move or resize. The
            // mirror coalesces wakeups and independently reads the native arrangement.
            changed?()
            return
        case kAXWindowMiniaturizedNotification: kind = UInt32(NP_APPLE_AX_MINIATURIZED)
        case kAXWindowDeminiaturizedNotification: kind = UInt32(NP_APPLE_AX_DEMINIATURIZED)
        default: return
        }
        read(kind, key: key, registration: registration)
    }

    private func read(_ kind: UInt32, key: DesktopWindowKey, registration: Registration) {
        guard let previous = order.begin(key, event: kind) else { return }
        reads.async { @Sendable [weak self] in
            let state = Self.confirm(kind, key: key, registration: registration, previous: previous)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.registrations[key.pid] === registration, self.desired[key.pid]?.contains(key) == true else { return }
                switch self.order.finish(key, confirmed: state) {
                case .readLatest(let event): self.read(event, key: key, registration: registration)
                case .refresh: self.changed?()
                case .idle: break
                }
            }
        }
    }

    private nonisolated static func confirm(_ kind: UInt32, key: DesktopWindowKey, registration: Registration, previous: UInt32) -> UInt32? {
        guard let window = registration.elements[key], let image = try? OrdinaryProcessImage.read(key.pid), image.launch == key.birth,
              let app = NSRunningApplication(processIdentifier: key.pid), !app.isHidden, !app.isTerminated, app.activationPolicy == .regular else { return nil }
        let registered = NPAppleMinimizeWindow(pid: key.pid, window: key.number, birth: key.birth)
        func read() -> (NPAppleMinimizeWindow, UInt32)? {
            var pid: pid_t = 0, value: CFTypeRef?
            guard AXUIElementGetPid(window, &pid) == .success, pid == key.pid,
                  AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == CFBooleanGetTypeID(), windowNumber(window) == key.number,
                  (try? OrdinaryProcessImage.read(key.pid)) == image else { return nil }
            let current = NPAppleMinimizeWindow(pid: pid, window: key.number, birth: image.launch)
            let state = UInt32(CFBooleanGetValue((value as! CFBoolean)) ? NP_APPLE_WINDOW_MINIMIZED : NP_APPLE_WINDOW_NORMAL)
            return (current, state)
        }
        guard let (current, state) = read(), previous != state else { return nil }
        let scope = UInt32(NP_APPLE_MINIMIZE_OBSERVING)
        if np_apple_native_minimize_change_v1(kind, registered, current, previous, state, scope) != NP_APPLE_MINIMIZE_NO_CHANGE { return state }
        // A delayed 'mini' may arrive after 'demini'. The old notice has no
        // authority. A second live, matching AX read can wake the native mirror.
        guard let (second, confirmed) = read(), confirmed == state else { return nil }
        return np_apple_native_minimize_change_v1(UInt32(NP_APPLE_MINIMIZE_SNAPSHOT), registered, second, previous, confirmed, scope)
            == NP_APPLE_MINIMIZE_NO_CHANGE ? nil : confirmed
    }
}
