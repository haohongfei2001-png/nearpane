import AppKit
import SwiftUI
import NearpaneCore

/// AppKit keeps delivering the drag to the source view. Resolve the drop in screen coordinates
/// against the destination Host panel, including letterboxed whitespace in the workspace row.
@MainActor final class WorkspacePointerRegistry {
    private let views = NSHashTable<WorkspacePointerView>.weakObjects()
    func register(_ view: WorkspacePointerView) { views.add(view) }
    func destination(at screen: NSPoint) -> WorkspaceID? {
        let hits = views.allObjects.compactMap { v -> WorkspaceID? in
            guard let window = v.window, window.isVisible, !v.isHiddenOrHasHiddenAncestor,
                  window.frame.contains(screen) else { return nil }
            return v.row(at: v.convert(window.convertPoint(fromScreen: screen), from: nil))
        }
        return hits.count == 1 ? hits[0] : nil
    }
}

struct WorkspacePointerSurface: NSViewRepresentable {
    let host: HostSession, preview: DesktopPreview, sample: DesktopSnapshot, display: SurfaceDisplay
    func makeNSView(context: Context) -> WorkspacePointerView { WorkspacePointerView() }
    func updateNSView(_ v: WorkspacePointerView, context: Context) {
        v.host = host; v.preview = preview; v.sample = sample; v.display = display
        display.pointer?.register(v)
    }
    static func dismantleNSView(_ view: WorkspacePointerView, coordinator: ()) {
        if view.held { view.host?.cancelWorkspaceGesture() }
    }
}

@MainActor final class WorkspacePointerView: NSView {
    weak var host: HostSession?, display: SurfaceDisplay?
    var preview: DesktopPreview?, sample: DesktopSnapshot?, held = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }
    func row(at p: NSPoint) -> WorkspaceID? {
        guard visibleRect.contains(p), let preview, let sample, host?.bus.desktop == sample,
              sample.nativeIsFresh(now: Date(), uptime: ProcessInfo.processInfo.systemUptime),
              let row = preview.rows.first(where: { $0.rowFrame.geometry.contains(.init(p.x,p.y)) }),
              case let .witnessedSpace(record) = row.kind else { return nil }
        return sample.workspaceID(display:row.displayID,record:record)
    }
    override func mouseDown(with event: NSEvent) {
        held = false
        guard let window, let host, let preview, let sample else { return }
        let p = convert(event.locationInWindow, from:nil), now = Date(), uptime = ProcessInfo.processInfo.systemUptime
        guard let row = row(at:p), let snapshot = host.workspaceSnapshot(primary:display?.primaryID, now:now, uptime:uptime) else { return }
        var id: ManagedWindowID?
        if case let .candidate(key) = preview.hit(x:p.x,y:p.y,current:sample,now:now,uptime:uptime),
           let w = sample.windows.first(where: { $0.id == key && $0.displayID == display?.id }),
           case let .known(ids) = w.membership, case let .native(_,_,record) = row, ids == [record] { id = ManagedWindowID(w) }
        let screen = window.convertPoint(toScreen:event.locationInWindow)
        host.pressWorkspace(row,window:id,x:screen.x,y:screen.y,snapshot:snapshot); held = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard held, let p = window?.convertPoint(toScreen:event.locationInWindow) else { return }
        host?.dragWorkspace(x:p.x,y:p.y)
    }
    override func mouseUp(with event: NSEvent) {
        guard held, let screen = window?.convertPoint(toScreen:event.locationInWindow) else { return }
        held = false
        host?.releaseWorkspace(on:display?.pointer?.destination(at:screen),x:screen.x,y:screen.y,primary:display?.primaryID,
                               now:Date(),uptime:ProcessInfo.processInfo.systemUptime)
    }
    override func cancelOperation(_ sender: Any?) { if held { held = false; host?.cancelWorkspaceGesture() } }
}
