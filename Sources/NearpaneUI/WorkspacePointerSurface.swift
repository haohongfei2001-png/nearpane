import AppKit
import NearpaneCore
import SwiftUI

@MainActor struct DesktopMapWindowSelection<Target: Equatable>: NSViewRepresentable {
    let target: (NSPoint) -> Target?
    let select: (Target) -> Void
    @Environment(\.isEnabled) private var enabled
    func makeNSView(context: Context) -> MapView { MapView() }
    func updateNSView(_ view: MapView, context: Context) {
        view.target = enabled ? target : nil
        view.select = select
        if !enabled { view.cancelOperation(nil) }
    }

    final class MapView: NSView {
        var target: ((NSPoint) -> Target?)?
        var select: ((Target) -> Void)?
        private var down: (NSPoint, Target, UUID)?
        override var isFlipped: Bool { true }
        override var needsPanelToBecomeKey: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            let navigation = NativeSidebarNavigation.shared
            down = nil
            guard navigation.dispatchAvailable, visibleRect.contains(p),
                  event.modifierFlags.intersection([.control, .option, .shift, .command]).isEmpty else { return }
            down = target?(p).map { (p, $0, navigation.ownershipEpoch) }
        }
        override func mouseDragged(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            if let (start, _, _) = down, hypot(p.x - start.x, p.y - start.y) >= 6 { down = nil }
        }
        override func mouseUp(with event: NSEvent) {
            defer { down = nil }
            let p = convert(event.locationInWindow, from: nil)
            guard let (start, original, epoch) = down, visibleRect.contains(p), NativeSidebarNavigation.shared.dispatchAvailable,
                  NativeSidebarNavigation.shared.ownershipEpoch == epoch, hypot(p.x - start.x, p.y - start.y) < 6,
                  let live = target?(p), original == live else { return }
            select?(live)
        }
        override func scrollWheel(with event: NSEvent) { down = nil; super.scrollWheel(with: event) }
        override func cancelOperation(_ sender: Any?) { down = nil }
        override func viewWillMove(toWindow newWindow: NSWindow?) { down = nil; super.viewWillMove(toWindow: newWindow) }
    }
}

/// AppKit keeps delivering the drag to the source view. Resolve the drop in screen coordinates
/// against the destination Host panel, including letterboxed whitespace in the workspace row.
@MainActor final class WorkspacePointerRegistry {
    weak var windowPreviews: WindowContentPreview?
    weak var navigation: NativeSidebarNavigation?
    private let views = NSHashTable<WorkspacePointerView>.weakObjects()
    func register(_ view: WorkspacePointerView) { views.add(view) }
    func destination(at screen: NSPoint) -> WorkspaceID? {
        let hits = views.allObjects.compactMap { v -> WorkspaceID? in
            guard let window = v.window, window.isVisible, !v.isHiddenOrHasHiddenAncestor,
                window.frame.contains(screen)
            else { return nil }
            return v.row(at: v.convert(window.convertPoint(fromScreen: screen), from: nil))
        }
        return hits.count == 1 ? hits[0] : nil
    }
}

struct WorkspacePointerSurface: NSViewRepresentable {
    let host: HostSession, preview: DesktopPreview, sample: DesktopSnapshot, display: SurfaceDisplay
    func makeNSView(context: Context) -> WorkspacePointerView { WorkspacePointerView() }
    func updateNSView(_ v: WorkspacePointerView, context: Context) {
        if v.held && v.sample?.revision != sample.revision { v.cancelOperation(nil) }
        v.host = host
        v.preview = preview
        v.sample = sample
        v.display = display
        display.pointer?.register(v)
    }
    static func dismantleNSView(_ view: WorkspacePointerView, coordinator: ()) {
        if view.held { view.host?.cancelWorkspaceGesture() }
    }
}

@MainActor final class WorkspacePointerView: NSView {
    weak var host: HostSession?, display: SurfaceDisplay?
    var preview: DesktopPreview?, sample: DesktopSnapshot?, held = false
    private var heldEpoch: UUID?
    private var navigation: NativeSidebarNavigation { display?.pointer?.navigation ?? .shared }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }
    func row(at p: NSPoint) -> WorkspaceID? {
        guard visibleRect.contains(p), let preview, let sample, host?.bus.desktop == sample,
            sample.nativeIsFresh(now: Date(), uptime: ProcessInfo.processInfo.systemUptime),
            let row = preview.rows.first(where: { $0.rowFrame.geometry.contains(.init(p.x, p.y)) }),
            case .witnessedSpace(let record) = row.kind
        else { return nil }
        return sample.workspaceID(display: row.displayID, record: record)
    }
    override func mouseDown(with event: NSEvent) {
        held = false
        guard navigation.dispatchAvailable, let window, let host, let preview, let sample else { return }
        let p = convert(event.locationInWindow, from: nil)
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        guard let row = row(at: p),
            let snapshot = host.workspaceSnapshot(primary: display?.primaryID, now: now, uptime: uptime)
        else { return }
        var id: ManagedWindowID?
        if case .candidate(let key) = preview.hit(x: p.x, y: p.y, current: sample, now: now, uptime: uptime),
            let w = sample.windows.first(where: { $0.id == key && $0.displayID == display?.id }),
            case .known(let ids) = w.membership, case .native(_, _, let record) = row, ids == [record]
        {
            id = ManagedWindowID(w)
        }
        let screen = window.convertPoint(toScreen: event.locationInWindow)
        host.pressWorkspace(row, window: id, x: screen.x, y: screen.y, snapshot: snapshot)
        heldEpoch = navigation.ownershipEpoch
        held = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard held, navigation.dispatchAvailable, heldEpoch == navigation.ownershipEpoch, let p = window?.convertPoint(toScreen: event.locationInWindow) else { return }
        host?.dragWorkspace(x: p.x, y: p.y)
    }
    override func mouseUp(with event: NSEvent) {
        guard held else { return }
        held = false
        guard navigation.dispatchAvailable, heldEpoch == navigation.ownershipEpoch,
              let screen = window?.convertPoint(toScreen: event.locationInWindow) else { return }
        host?.releaseWorkspace(
            on: display?.pointer?.destination(at: screen), x: screen.x, y: screen.y, primary: display?.primaryID,
            now: Date(), uptime: ProcessInfo.processInfo.systemUptime)
    }
    override func scrollWheel(with event: NSEvent) {
        if held { cancelOperation(nil) }
        super.scrollWheel(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if held {
            held = false
            host?.cancelWorkspaceGesture()
        }
    }
}
