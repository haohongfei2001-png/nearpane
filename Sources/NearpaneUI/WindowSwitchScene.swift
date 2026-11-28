import AppKit
import NearpaneCore
import WindowGeometryCore
@preconcurrency import ScreenCaptureKit

/// Only the part of the old window the selection will actually uncover. All frames
/// are in global Quartz points until the final conversion for the AppKit panel.
struct WindowSwitchScene {
    struct Surface: Equatable {
        let number: CGWindowID
        let pid: pid_t
        let frame: CGRect

        init(number: CGWindowID, pid: pid_t, frame: CGRect) {
            self.number = number; self.pid = pid; self.frame = frame
        }

        init?(_ row: [String: Any]) {
            guard row[kCGWindowLayer as String] as? Int == 0,
                  let number = row[kCGWindowNumber as String] as? UInt32,
                  let pid = row[kCGWindowOwnerPID as String] as? Int32,
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), !frame.isEmpty, !frame.isInfinite,
                  (row[kCGWindowAlpha as String] as? Double ?? 0) > 0 else { return nil }
            self.init(number: number, pid: pid, frame: frame)
        }
    }
    enum Order { case original, selecting, selected, changed }
    struct Patch: Equatable {
        let donor: Surface, bounds: CGRect
    }

    let source, target: DesktopWindowTarget
    let sourceWindow, targetWindow: Surface
    let patch: Patch
    let displayID: CGDirectDisplayID
    let displayBounds, panelFrame: CGRect
    let scale: CGFloat

    static func patch(source: Surface, target: Surface, on display: CGRect, stack: [Surface]) -> Patch? {
        guard source.number != target.number, display.contains(target.frame),
              let front = stack.first(where: { $0.frame.intersects(display) }), front == source,
              let index = stack.firstIndex(of: target) else { return nil }
        let overlap = source.frame.intersection(target.frame)
        if !overlap.isEmpty { return Patch(donor: source, bounds: overlap) }
        // For side-by-side windows, dissolve the selected window's inactive appearance
        // into its live, active appearance only where it was already unobscured.
        guard !stack[..<index].contains(where: { $0.frame.intersects(target.frame) }) else { return nil }
        return Patch(donor: target, bounds: target.frame)
    }

    static func stack() -> [Surface] {
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        return rows?.compactMap(Surface.init) ?? []
    }

    @MainActor init?(target: DesktopWindowTarget, snapshot: DesktopSnapshot) {
        guard snapshot.native?.stageManagerEnabled == false, target.publiclyVisible, let space = target.current,
              snapshot.scopes.first(where: { $0.displayID == target.display })?.records.contains(where: {
                  $0.id == space && $0.isCurrent && $0.ordinaryUUID != nil
              }) == true, target.present(in: snapshot),
              let screen = NSScreen.screens.first(where: { screen in
                  guard let id = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber,
                        let uuid = CGDisplayCreateUUIDFromDisplayID(id.uint32Value)?.takeRetainedValue() else { return false }
                  return (CFUUIDCreateString(nil, uuid) as String).caseInsensitiveCompare(target.display) == .orderedSame
              }), let id = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber,
              CGDisplayIsInMirrorSet(id.uint32Value) == 0 else { return nil }
        let display = CGDisplayBounds(id.uint32Value), stack = Self.stack()
        guard let front = stack.first(where: { $0.frame.intersects(display) }),
              front.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let source = snapshot.currentDesktopWindows(on: target.display, now: .now, uptime: ProcessInfo.processInfo.systemUptime).first(where: {
                  $0.metadata?.number == front.number && $0.metadata?.pid == front.pid
              }).flatMap({ DesktopWindowTarget($0, in: snapshot) }), source.publiclyVisible, source.current == space,
              source.matches(front.frame), let dest = stack.first(where: { $0.number == target.key.number }),
              dest.pid == target.key.pid, target.matches(dest.frame),
              let patch = Self.patch(source: front, target: dest, on: display, stack: stack),
              let rotation = QuarterTurn(rawValue: Int(CGDisplayRotation(id.uint32Value).rounded()) % 360),
              let transform = try? DisplayCoordinateTransform(displayID: target.display,
                  appKitFrame: Rect(screen.frame.minX, screen.frame.minY, screen.frame.width, screen.frame.height),
                  cgBounds: Rect(display.minX, display.minY, display.width, display.height),
                  backingScale: screen.backingScaleFactor, rotation: rotation),
              let panel = try? transform.cgToAppKit(Rect(patch.bounds.minX, patch.bounds.minY, patch.bounds.width, patch.bounds.height))
        else { return nil }
        self.source = source; self.target = target; sourceWindow = front; targetWindow = dest
        self.patch = patch; displayID = id.uint32Value; displayBounds = display; scale = screen.backingScaleFactor
        panelFrame = CGRect(x: panel.x, y: panel.y, width: panel.width, height: panel.height)
    }

    static func order(source: Surface, target: Surface, patch: Patch, display: CGRect, stack: [Surface], frontPID: pid_t?) -> Order {
        guard stack.contains(source), stack.contains(target),
              let first = stack.first(where: { $0.frame.intersects(display) }),
              frontPID == source.pid || frontPID == target.pid else { return .changed }
        if first == target { return frontPID == target.pid ? .selected : .selecting }
        if first == source, Self.patch(source: source, target: target, on: display, stack: stack) == patch {
            return frontPID == source.pid ? .original : .selecting
        }
        return .changed
    }

    @MainActor func order() -> Order {
        Self.order(source: sourceWindow, target: targetWindow, patch: patch, display: displayBounds,
                   stack: Self.stack(), frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }

    /// One display-local crop of one explicitly identified window. No desktop,
    /// sibling, pointer or audio is included, including on secondary displays.
    @MainActor func capture(window: SCWindow, on display: SCDisplay) async throws -> CGImage? {
        let donor = patch.donor
        guard display.displayID == displayID, display.frame == displayBounds,
              window.windowID == donor.number, window.owningApplication?.processID == donor.pid,
              window.isOnScreen, window.windowLayer == 0, window.frame == donor.frame else { return nil }
        let filter = SCContentFilter(display: display, including: [window])
        if #available(macOS 14.2, *) { filter.includeMenuBar = false }
        let cfg = WindowFrameStream.sRGBConfiguration()
        cfg.sourceRect = patch.bounds.offsetBy(dx: -displayBounds.minX, dy: -displayBounds.minY)
        let density = min(scale, sqrt(8_388_608 / (patch.bounds.width * patch.bounds.height)))
        guard density >= 1 else { return nil }
        cfg.width = max(1, Int((patch.bounds.width * density).rounded(.down)))
        cfg.height = max(1, Int((patch.bounds.height * density).rounded(.down)))
        cfg.backgroundColor = CGColor.clear; cfg.shouldBeOpaque = false
        cfg.showsCursor = false; cfg.capturesAudio = false; cfg.ignoreShadowsDisplay = true
        if #available(macOS 14.2, *) { cfg.includeChildWindows = false }
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        return image.width == cfg.width && image.height == cfg.height ? image : nil
    }
}
