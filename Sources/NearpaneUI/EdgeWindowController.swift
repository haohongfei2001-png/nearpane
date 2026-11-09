import AppKit
import SwiftUI
import NearpaneCore

public final class EdgePanel: NSPanel {
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    public override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !isKeyWindow, let content = contentView,
           let text = content.hitTest(content.convert(event.locationInWindow, from: nil)) as? NSTextView,
           text.isEditable {
            makeKey()
            makeFirstResponder(text)
        }
        super.sendEvent(event)
    }
}

private final class SurfaceHostingView: NSHostingView<EdgeSurfaceView> {
    // Button clicks do not become key. An explicitly clicked native text editor can opt in.
    override var needsPanelToBecomeKey: Bool { false }
}

@MainActor
public final class EdgeWindowController: NSWindowController {
    private let host: HostSession
    private let modules: EmbeddedModules?
    private let display = SurfaceDisplay()
    private var captureSuppressed = false
    public private(set) var hasPlacement = false
    public init(host: HostSession, modules: EmbeddedModules? = nil) {
        self.host = host; self.modules = modules
        let panel = EdgePanel(contentRect: NSRect(x: 0, y: 0, width: 180, height: 800),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.title = ""
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let material = NSVisualEffectView()
        material.material = .sidebar
        material.blendingMode = .behindWindow
        material.state = .active
        let content = SurfaceHostingView(rootView: EdgeSurfaceView(host: host, modules: modules, display: display))
        content.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            content.topAnchor.constraint(equalTo: material.topAnchor),
            content.bottomAnchor.constraint(equalTo: material.bottomAnchor)
        ])
        panel.contentView = material
        super.init(window: panel)
        #if canImport(NearpaneTray)
        modules?.tray.exposureChanged = { [weak self] hidden in
            guard let self, captureSuppressed != hidden else { return }
            captureSuppressed = hidden
            presentIfNeeded()
        }
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    public func place(screens: [ScreenGeometry]) {
        guard let rect = SurfacePlacement.resolve(screens: screens, preferredID: host.configuration.preferredDisplayID,
                                                  edge: host.configuration.edge) else {
            display.id = nil
            hasPlacement = false
            hide()
            return
        }
        window?.setFrame(NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height), display: false)
        display.id = screens.first { screen in
            screen.frame.geometry.contains(.init(rect.x + rect.width/2, rect.y + rect.height/2))
        }?.id
        hasPlacement = true
    }

    /// Never called by build scripts or tests. User launch is the only automatic presentation path.
    public func presentIfNeeded() {
        guard host.isRunning, hasPlacement, !captureSuppressed, !host.configuration.surfaceHidden else { hide(); return }
        modules?.setInteractionHidden(false)
        if window?.isVisible == false { window?.orderFront(nil) }
    }
    public func hide() { modules?.setInteractionHidden(true); window?.orderOut(nil) }
}

@MainActor
public enum SystemScreens {
    public static func geometry() -> [ScreenGeometry] {
        // NSScreen.screens[0] is the menu-bar display, independent of the user's current key window.
        NSScreen.screens.map { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            let id: String
            if let number, let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() {
                id = CFUUIDCreateString(nil, uuid) as String
            } else { id = "unidentified-display" }
            return ScreenGeometry(id: id, frame: rect(screen.frame), visibleFrame: rect(screen.visibleFrame))
        }
    }

    private static func rect(_ rect: NSRect) -> SurfaceRect {
        SurfaceRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }
}
