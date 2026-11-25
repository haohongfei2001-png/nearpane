import AppKit
import ApplicationServices
import CReadOnlySpaces
import NearpaneCore

/// A miniaturized window present before observation is not an instruction to Nearpane.
/// Only a previously witnessed visible window followed by its actual AX notification
/// can enter the independent engine's minimize transaction.
struct IndependentStageMinimizeOrder {
    enum Event: Equatable, Sendable { case snapshot, miniaturized, deminiaturized }
    private var armed = Set<DesktopWindowKey>()

    mutating func observe(_ key: DesktopWindowKey, event: Event, minimized: Bool, onscreen: Bool) -> Bool {
        switch event {
        case .snapshot:
            // A roster read may beat delivery of the corresponding AX notice. A
            // minimized snapshot must not consume the prior visible observation.
            if !minimized && onscreen { armed.insert(key) }
            return false
        case .deminiaturized:
            // The Spaces transaction clears AXMinimized while offscreen. That is
            // our own acknowledgment, not a newly visible user window.
            if !minimized && onscreen { armed.insert(key) }
            else { armed.remove(key) }
            return false
        case .miniaturized:
            guard minimized, !onscreen else { return false }
            return armed.remove(key) != nil
        }
    }

    mutating func remove(_ key: DesktopWindowKey) { armed.remove(key) }
    mutating func retain(_ keys: Set<DesktopWindowKey>) { armed.formIntersection(keys) }
}

/// Uses ordinary per-window Accessibility notifications even when Apple Stage Manager
/// is off. It does not intercept clicks or write AXMinimized. The Rust/C Spaces
/// transaction moves the real window first and clears native minimization while hidden.
@MainActor final class IndependentStageMinimizeObserver {
    typealias Minimized = @MainActor (DesktopWindowKey) -> Void
    typealias Changed = @MainActor () -> Void
    private let queue = DispatchQueue(label: "Nearpane.IndependentStage.minimize", qos: .userInitiated)
    private var desired = [pid_t: Set<DesktopWindowKey>]()
    private var registrations = [pid_t: Registration]()
    private var preparing = [pid_t: UUID]()
    private var sampling = Set<pid_t>()
    private var order = IndependentStageMinimizeOrder()
    private var minimized: Minimized?, changed: Changed?

    private struct Reading: Sendable { let minimized, onscreen: Bool }
    private final class Registration: @unchecked Sendable {
        let observer: AXObserver
        let keys: Set<DesktopWindowKey>
        let elements: [DesktopWindowKey: AXUIElement]
        let initial: [DesktopWindowKey: Reading]
        init(observer: AXObserver, keys: Set<DesktopWindowKey>, elements: [DesktopWindowKey: AXUIElement],
             initial: [DesktopWindowKey: Reading]) {
            self.observer = observer; self.keys = keys; self.elements = elements; self.initial = initial
        }
    }
    private final class Destination { weak var value: IndependentStageMinimizeObserver? }
    private static var destinations = [ObjectIdentifier: Destination]()

    isolated deinit { stop() }

    func update(targets: [DesktopWindowKey], minimized: @escaping Minimized, changed: @escaping Changed) {
        guard !targets.isEmpty, AXIsProcessTrusted(), !StageManagerPreference.ownsWindowDispatch else { stop(); return }
        desired = AppleStageMinimizeObserver.admitted(targets, ownPID: getpid())
        self.minimized = minimized; self.changed = changed
        order.retain(Set(desired.values.flatMap { $0 }))
        for (pid, existing) in registrations where existing.keys != desired[pid] { detach(pid) }
        for pid in preparing.keys where desired[pid] == nil { preparing.removeValue(forKey: pid) }
        for (pid, keys) in desired {
            if let existing = registrations[pid] { refresh(existing, pid: pid); continue }
            guard preparing[pid] == nil else { continue }
            let token = UUID(); preparing[pid] = token
            queue.async { @Sendable [weak self] in
                let prepared = Self.prepare(pid, keys: keys)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.preparing[pid] == token else { return }
                    self.preparing.removeValue(forKey: pid)
                    guard self.desired[pid] == keys, let prepared else { return }
                    self.registrations[pid] = prepared
                    for (key, state) in prepared.initial {
                        _ = self.order.observe(key, event: .snapshot, minimized: state.minimized, onscreen: state.onscreen)
                    }
                    let destination = Destination(); destination.value = self
                    Self.destinations[ObjectIdentifier(prepared.observer)] = destination
                    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(prepared.observer), .commonModes)
                }
            }
        }
    }

    func observes(_ key: DesktopWindowKey) -> Bool { registrations[key.pid]?.elements[key] != nil }

    func stop() {
        desired.removeAll(); preparing.removeAll(); sampling.removeAll()
        for pid in Array(registrations.keys) { detach(pid) }
        order = IndependentStageMinimizeOrder(); minimized = nil; changed = nil
    }

    private func detach(_ pid: pid_t) {
        guard let old = registrations.removeValue(forKey: pid) else { return }
        sampling.remove(pid)
        Self.destinations.removeValue(forKey: ObjectIdentifier(old.observer))
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old.observer), .commonModes)
        for key in old.keys { order.remove(key) }
    }

    private nonisolated static func number(_ element: AXUIElement) -> UInt32 {
        let direct = NPReadAXWindowNumber(element)
        if direct > 0 { return direct }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXWindowNumber" as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFNumberGetTypeID(), let n = value as? NSNumber else { return 0 }
        return UInt32(exactly: n.int64Value) ?? 0
    }

    private nonisolated static func read(_ key: DesktopWindowKey, element: AXUIElement) -> Reading? {
        guard let image = try? OrdinaryProcessImage.read(key.pid), image.launch == key.birth,
              AXUIElementSetMessagingTimeout(element, .06) == .success else { return nil }
        var pid: pid_t = 0, value: CFTypeRef?
        guard AXUIElementGetPid(element, &pid) == .success, pid == key.pid, number(element) == key.number,
              AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFBooleanGetTypeID(),
              let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, key.number) as? [[String: Any]],
              rows.count == 1, let row = rows.first,
              (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value == key.number,
              (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == key.pid,
              let screen = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]],
              (try? OrdinaryProcessImage.read(key.pid)) == image else { return nil }
        let onscreen = screen.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == key.number }
        return Reading(minimized: CFBooleanGetValue((value as! CFBoolean)), onscreen: onscreen)
    }

    private nonisolated static func prepare(_ pid: pid_t, keys: Set<DesktopWindowKey>) -> Registration? {
        guard let birth = keys.first?.birth, let image = try? OrdinaryProcessImage.read(pid), image.launch == birth else { return nil }
        let app = AXUIElementCreateApplication(pid)
        guard AXUIElementSetMessagingTimeout(app, .08) == .success else { return nil }
        var raw: CFArray?, count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(app, kAXWindowsAttribute as CFString, &count) == .success, count <= 256, count >= 0,
              AXUIElementCopyAttributeValues(app, kAXWindowsAttribute as CFString, 0, count, &raw) == .success,
              let windows = raw as? [AXUIElement] else { return nil }
        let callback: AXObserverCallback = { observer, element, event, _ in
            MainActor.assumeIsolated {
                IndependentStageMinimizeObserver.destinations[ObjectIdentifier(observer)]?.value?.receive(observer, element: element, event: event as String)
            }
        }
        var observer: AXObserver?
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return nil }
        var elements = [DesktopWindowKey: AXUIElement](), states = [DesktopWindowKey: Reading]()
        var duplicates = Set<DesktopWindowKey>()
        for element in windows {
            let key = DesktopWindowKey(pid: pid, birth: birth, number: number(element))
            guard keys.contains(key), !duplicates.contains(key) else { continue }
            if elements[key] != nil { elements.removeValue(forKey: key); states.removeValue(forKey: key); duplicates.insert(key); continue }
            guard let state = read(key, element: element) else { continue }
            guard AXObserverAddNotification(observer, element, kAXWindowMiniaturizedNotification as CFString, nil) == .success else { continue }
            for notification in [kAXWindowDeminiaturizedNotification, kAXUIElementDestroyedNotification,
                                 kAXWindowMovedNotification, kAXWindowResizedNotification] {
                _ = AXObserverAddNotification(observer, element, notification as CFString, nil)
            }
            elements[key] = element; states[key] = state
        }
        for notification in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] {
            _ = AXObserverAddNotification(observer, app, notification as CFString, nil)
        }
        guard !elements.isEmpty, (try? OrdinaryProcessImage.read(pid)) == image else { return nil }
        return Registration(observer: observer, keys: keys, elements: elements, initial: states)
    }

    private func refresh(_ registration: Registration, pid: pid_t) {
        guard sampling.insert(pid).inserted else { return }
        queue.async { @Sendable [weak self] in
            var sampled = [DesktopWindowKey: Reading]()
            for (key, element) in registration.elements {
                if let state = Self.read(key, element: element) { sampled[key] = state }
            }
            let observations = sampled
            DispatchQueue.main.async { [weak self] in
                guard let self, self.registrations[pid] === registration else { return }
                self.sampling.remove(pid)
                for (key, state) in observations {
                    _ = self.order.observe(key, event: .snapshot, minimized: state.minimized, onscreen: state.onscreen)
                }
            }
        }
    }

    private func receive(_ observer: AXObserver, element: AXUIElement, event: String) {
        guard !StageManagerPreference.ownsWindowDispatch,
              let registration = registrations.values.first(where: { $0.observer === observer }) else { return }
        if event == kAXWindowCreatedNotification || event == kAXFocusedWindowChangedNotification {
            changed?(); return
        }
        guard let (key, _) = registration.elements.first(where: { CFEqual($0.value, element) }), desired[key.pid]?.contains(key) == true else { return }
        if event == kAXUIElementDestroyedNotification { detach(key.pid); changed?(); return }
        let kind: IndependentStageMinimizeOrder.Event
        switch event {
        case kAXWindowMiniaturizedNotification: kind = .miniaturized
        case kAXWindowDeminiaturizedNotification: kind = .deminiaturized
        case kAXWindowMovedNotification, kAXWindowResizedNotification: changed?(); return
        default: return
        }
        queue.async { @Sendable [weak self] in
            guard let target = registration.elements[key] else { return }
            var state = Self.read(key, element: target)
            // A native miniaturization notification can precede the final compositor
            // frame. Read again for at most 500 ms; no UI thread is blocked.
            if kind == .miniaturized {
                let end = ProcessInfo.processInfo.systemUptime + .5
                while state?.minimized == true && state?.onscreen == true && ProcessInfo.processInfo.systemUptime < end {
                    Thread.sleep(forTimeInterval: .02)
                    state = Self.read(key, element: target)
                }
            }
            let observed = state
            DispatchQueue.main.async { [weak self] in
                guard let self, self.registrations[key.pid] === registration, self.desired[key.pid]?.contains(key) == true,
                      !StageManagerPreference.ownsWindowDispatch, let observed else { return }
                let requested = self.order.observe(key, event: kind, minimized: observed.minimized, onscreen: observed.onscreen)
                self.changed?()
                if requested { self.minimized?(key) }
            }
        }
    }
}
