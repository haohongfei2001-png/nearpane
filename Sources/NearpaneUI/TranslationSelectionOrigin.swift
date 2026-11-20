import AppKit
import ApplicationServices

/// AppKit's Services callback has no sender parameter. Use an IPC peer only when Foundation
/// is dispatching this message to the registered provider itself. The caller can be unknown.
enum TranslationCaller {
    static func direct(pid: pid_t?, exactProvider: Bool, sameUser: Bool, host: pid_t) -> pid_t? {
        guard exactProvider, sameUser, let pid, pid > 1, pid != host else { return nil }
        return pid
    }

    static func atCallback(to provider: AnyObject) -> SelectionForeground? {
        guard let connection = NSXPCConnection.current() else { return nil }
        let peer = direct(pid: connection.processIdentifier, exactProvider: (connection.exportedObject as AnyObject?) === provider,
                          sameUser: connection.effectiveUserIdentifier == getuid(), host: getpid())
        return SelectionForeground.read(peer)
    }
}

struct TranslationInputIdentity<Element: Equatable>: Equatable {
    let owner: SelectionForeground
    let field: Element
    let window: Element
    let range: NSRange

    func matches(owner: SelectionForeground, field: Element, window: Element) -> Bool {
        self.owner == owner && self.field == field && self.window == window
    }
}

enum TranslationPlacement: Equatable {
    case selection(NSRect)
    case pointer(NSPoint)

    static func selectedRect(_ rect: NSRect?) -> Self? {
        guard let rect, rect.width > 0, rect.height > 0, rect.minX.isFinite, rect.minY.isFinite,
              rect.maxX.isFinite, rect.maxY.isFinite else { return nil }
        return .selection(rect)
    }

    static func pointerAt(_ point: NSPoint, insideOriginalWindow: Bool) -> Self? {
        guard insideOriginalWindow, point.x.isFinite, point.y.isFinite else { return nil }
        return .pointer(point)
    }
}

/// A generic feedback location for this request. The ambient process is solely an
/// interruption guard. It never authorizes a read of that application's AX controls or text.
struct TranslationFeedbackPointer: Equatable {
    let foreground: SelectionForeground
    let display: CGDirectDisplayID
    let screenFrame: NSRect
    let visibleFrame: NSRect
    let point: NSPoint
    let activity: [UInt32]

    init?(foreground: SelectionForeground?, display: CGDirectDisplayID, screenFrame: NSRect, visibleFrame: NSRect,
          point: NSPoint, activity: [UInt32]) {
        guard let foreground, display != 0, !activity.isEmpty, point.x.isFinite, point.y.isFinite,
              !visibleFrame.isEmpty, screenFrame.contains(visibleFrame), screenFrame.contains(point) else { return nil }
        self.foreground = foreground
        self.display = display
        self.screenFrame = screenFrame
        self.visibleFrame = visibleFrame
        self.point = point
        self.activity = activity
    }

    @MainActor static func capture() -> Self? {
        func foreground() -> SelectionForeground? {
            SelectionForeground.read(NSWorkspace.shared.frontmostApplication?.processIdentifier)
        }
        func activity() -> [UInt32] {
            let movement: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
            return NativeSelectionPermit.inputCounters() + movement.map { CGEventSource.counterForEventType(.hidSystemState, eventType: $0) }
        }
        let counts = activity(), context = foreground(), point = NSEvent.mouseLocation
        let screens = NSScreen.screens.filter { $0.frame.contains(point) }
        guard screens.count == 1, let screen = screens.first,
              let display = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
              CGDisplayIsActive(display) != 0, CGDisplayIsAsleep(display) == 0,
              activity() == counts, foreground() == context, NSEvent.mouseLocation == point else { return nil }
        return .init(foreground: context, display: display, screenFrame: screen.frame, visibleFrame: screen.visibleFrame, point: point, activity: counts)
    }
}

/// Retained for one service request. Only an authenticated, currently focused process is
/// queried. Its controls, window, selection range and caller identity stay in memory.
@MainActor final class TranslationSelectionOrigin {
    private struct Element: Equatable {
        let ax: AXUIElement
        static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.ax, rhs.ax) }
    }

    private let application: NSRunningApplication
    private let identity: TranslationInputIdentity<Element>
    var owner: SelectionForeground { identity.owner }

    private init(application: NSRunningApplication, identity: TranslationInputIdentity<Element>) {
        self.application = application
        self.identity = identity
    }

    static func capture(peer owner: SelectionForeground, source: String) -> TranslationSelectionOrigin? {
        guard owner.pid != getpid(), let app = NSRunningApplication(processIdentifier: owner.pid), isCurrent(app, owner),
              let identity = AXRead().input(owner: owner, source: source), isCurrent(app, owner) else { return nil }
        return .init(application: app, identity: identity)
    }

    func placement(for source: String, pointer: TranslationFeedbackPointer?) -> TranslationPlacement? {
        guard Self.isCurrent(application, owner) else { return nil }
        let read = AXRead()
        guard read.input(owner: owner, source: source, original: identity) == identity,
              let primary = NSScreen.screens.first else { return nil }

        let placement: TranslationPlacement?
        if let rect = read.bounds(field: identity.field.ax, range: identity.range),
           let selected = TranslationPlacement.selectedRect(NSRect(x: rect.minX, y: primary.frame.maxY - rect.maxY,
                                                                width: rect.width, height: rect.height)) {
            placement = selected
        } else if let pointer, TranslationFeedbackPointer.capture() == pointer {
            let point = CGPoint(x: pointer.point.x, y: primary.frame.maxY - pointer.point.y)
            placement = .pointerAt(pointer.point, insideOriginalWindow: read.pointer(point, belongsTo: identity))
        } else {
            placement = nil
        }
        guard let placement, Self.isCurrent(application, owner),
              read.input(owner: owner, source: source, original: identity) == identity, Self.isCurrent(application, owner) else { return nil }
        return placement
    }

    private static func isCurrent(_ app: NSRunningApplication, _ owner: SelectionForeground) -> Bool {
        !app.isTerminated && NSWorkspace.shared.frontmostApplication?.processIdentifier == owner.pid &&
            SelectionForeground.read(app.processIdentifier) == owner
    }

    private struct AXRead {
        // The source can be waiting inside NSPerformService. Bound its synchronous AX reads.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.18

        func ready(_ element: AXUIElement) -> Bool {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            return remaining > 0 && AXUIElementSetMessagingTimeout(element, Float(remaining)) == .success
        }

        func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var raw: CFTypeRef?
            guard ready(element), AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success else { return nil }
            return raw
        }

        func element(_ ax: AXUIElement, _ name: String) -> Element? {
            guard let value = value(ax, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return .init(ax: value as! AXUIElement)
        }

        func belongs(_ element: AXUIElement, to pid: pid_t) -> Bool {
            var observed: pid_t = 0
            return AXUIElementGetPid(element, &observed) == .success && observed == pid
        }

        func selectedRange(_ field: AXUIElement) -> NSRange? {
            guard let value = value(field, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            var range = CFRange()
            guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length > 0,
                  range.location <= Int.max - range.length else { return nil }
            return NSRange(location: range.location, length: range.length)
        }

        func input(owner: SelectionForeground, source: String, original: TranslationInputIdentity<Element>? = nil) -> TranslationInputIdentity<Element>? {
            let app = AXUIElementCreateApplication(owner.pid)
            guard let field = element(app, kAXFocusedUIElementAttribute), belongs(field.ax, to: owner.pid),
                  let window = element(field.ax, kAXWindowAttribute), belongs(window.ax, to: owner.pid),
                  element(app, kAXFocusedWindowAttribute) == window else { return nil }
            // A different field or window inside this application may contain private text.
            if let original, !original.matches(owner: owner, field: field, window: window) { return nil }
            guard let range = selectedRange(field.ax), range.length == (source as NSString).length,
                  original == nil || original?.range == range,
                  let selected = value(field.ax, kAXSelectedTextAttribute) as? String, selected.utf8.elementsEqual(source.utf8),
                  selectedRange(field.ax) == range, element(app, kAXFocusedUIElementAttribute) == field,
                  element(field.ax, kAXWindowAttribute) == window, element(app, kAXFocusedWindowAttribute) == window else { return nil }
            return .init(owner: owner, field: field, window: window, range: range)
        }

        func bounds(field: AXUIElement, range: NSRange) -> CGRect? {
            var range = CFRange(location: range.location, length: range.length)
            var value: CFTypeRef?
            var rect = CGRect.zero
            guard ready(field), let axRange = AXValueCreate(.cfRange, &range),
                  AXUIElementCopyParameterizedAttributeValue(field, kAXBoundsForRangeParameterizedAttribute as CFString, axRange, &value) == .success,
                  let value, CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetValue(value as! AXValue, .cgRect, &rect),
                  !rect.isEmpty else { return nil }
            return rect
        }

        func pointer(_ p: CGPoint, belongsTo input: TranslationInputIdentity<Element>) -> Bool {
            var hit: AXUIElement?
            // Changing the timeout on the system-wide AX element changes it for the whole Host.
            guard p.x.isFinite, p.y.isFinite, ProcessInfo.processInfo.systemUptime < deadline,
                  AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &hit) == .success,
                  let hit, belongs(hit, to: input.owner.pid), ProcessInfo.processInfo.systemUptime < deadline else { return false }
            return CFEqual(hit, input.window.ax) || element(hit, kAXWindowAttribute) == input.window
        }
    }
}
