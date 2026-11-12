import AppKit
import SwiftUI
import NearpaneCore

public final class EdgePanel: NSPanel {
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    var floatBounds: NSRect? { didSet { if floatBounds != oldValue { floatDrag = nil } } }
    var floatMoved: ((NSPoint) -> Void)?
    fileprivate var draggingFloating: Bool { floatDrag != nil }
    fileprivate func cancelFloatingDrag() { floatDrag = nil }
    private var floatDrag: (origin:NSPoint, pointer:NSPoint)?
    public override func sendEvent(_ event: NSEvent) {
        if let bounds = floatBounds {
            if event.type == .leftMouseDown, event.modifierFlags.contains(.option) {
                floatDrag = (frame.origin,convertPoint(toScreen:event.locationInWindow)); return
            }
            if let start = floatDrag, event.type == .leftMouseDragged || event.type == .leftMouseUp {
                let p = convertPoint(toScreen:event.locationInWindow)
                let x = min(bounds.maxX-frame.width,max(bounds.minX,start.origin.x+p.x-start.pointer.x))
                let y = min(bounds.maxY-frame.height,max(bounds.minY,start.origin.y+p.y-start.pointer.y))
                setFrameOrigin(.init(x:x,y:y))
                if event.type == .leftMouseUp {
                    floatDrag = nil; floatMoved?(.init(x:frame.minX-bounds.minX,y:frame.minY-bounds.minY))
                }
                return
            }
        }
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

private final class FoldedHostingView: NSHostingView<FoldedSurfaceButton> {
    override var needsPanelToBecomeKey: Bool { false }
}

@MainActor
public final class EdgeWindowController: NSWindowController {
    private let host: HostSession
    private let modules: EmbeddedModules?
    private let display = SurfaceDisplay()
    private var presentationAllowed = true
    private(set) var captureSuppressed = false
    var exposureDidChange: (() -> Void)?
    public private(set) var hasPlacement = false
    public private(set) var requestedFrame: NSRect?
    private var placedFrame: NSRect?
    private let container = NSView()
    private let material = NSVisualEffectView()
    private let contentView: SurfaceHostingView
    private var contentBottom: NSLayoutConstraint
    private var foldedView: FoldedHostingView?
    private var closeExpansion: NSButton?
    private var placement: (screen: ScreenGeometry, primary: String, content: PanelContent)?
    private var placementGeneration: UInt64 = 0
    private var savedPanelWidth: Measure?, savedPanelHeight: Measure?
    private var folded = false
    private var interactionHidden: Bool?
    private(set) var temporarilyExpanded = false
    public init(host: HostSession, modules: EmbeddedModules? = nil) {
        self.host = host; self.modules = modules
        let panel = EdgePanel(contentRect: NSRect(x: 0, y: 0, width: 180, height: 800),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        // WindowServer zoom can temporarily extend a full-height edge panel onto a neighboring screen.
        // Keep window geometry fixed; domain controls own their internal animations.
        panel.animationBehavior = .none
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenNone, .stationary, .ignoresCycle]
        material.material = .sidebar
        material.blendingMode = .behindWindow
        material.state = .active
        // Only the folded or foundation host uses this system backdrop. The full
        // product draws the shared rail glass once behind all three modules.
        material.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(material)
        NSLayoutConstraint.activate([
            material.topAnchor.constraint(equalTo: container.topAnchor),
            material.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            material.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            material.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        let content = SurfaceHostingView(rootView: EdgeSurfaceView(host: host, modules: modules, display: display))
        contentView = content
        contentBottom = content.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        content.sizingOptions = []
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            contentBottom
        ])
        panel.contentView = container
        super.init(window: panel)
        #if canImport(NearpaneTray)
        modules?.tray.exposureChanged = { [weak self] hidden in
            guard let self, captureSuppressed != hidden else { return }
            captureSuppressed = hidden
            if let exposureDidChange { exposureDidChange() } else { presentIfNeeded() }
        }
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    public func place(screens: [ScreenGeometry]) {
        let usable = MultiDisplayPresentationCoordinator.identifiedScreens(screens)
        guard let screen = usable.first(where: { $0.id == host.configuration.preferredDisplayID }) ?? usable.first else {
            removePlacement(); return
        }
        place(on:screen,primary:screen.id,content:.full)
    }

    func removePlacement() {
        guard placement != nil || window?.isVisible == true else {
            updateInteraction(hidden: true)
            return
        }
        endPlacementInteractions()
        if window?.isVisible == true { window?.orderOut(nil) }
        hasPlacement = false
        temporarilyExpanded = false
        placement = nil
        display.content = .hidden
        display.id = nil
    }

    private func endPlacementInteractions() {
        placementGeneration += 1
        if let panel = window as? EdgePanel {
            panel.cancelFloatingDrag()
            panel.floatBounds = nil
            panel.floatMoved = nil
            if panel.isKeyWindow {
                panel.makeFirstResponder(nil)
                panel.orderOut(nil)
            }
        }
        host.cancelWorkspaceGesture()
        updateInteraction(hidden: true)
    }

    func usePointer(_ registry: WorkspacePointerRegistry) { display.pointer = registry }
    public func place(on screen: ScreenGeometry, primary: String, content: PanelContent) {
        if let placement, placement.screen != screen || placement.primary != primary {
            endPlacementInteractions()
        }
        let config = host.configuration.displays[screen.id] ?? .init()
        if display.id != screen.id || display.primaryID != primary || content == .hidden
            || savedPanelWidth != config.measures[.panelWidth] || savedPanelHeight != config.measures[.panelHeight] {
            temporarilyExpanded = false
        }
        savedPanelWidth = config.measures[.panelWidth]
        savedPanelHeight = config.measures[.panelHeight]
        placement = (screen, primary, content)
        display.id = screen.id; display.primaryID = primary
        display.secondary = screen.id != primary; display.content = content
        let floating = display.secondary && config.placement == .floating
        presentationAllowed = content != .hidden
        let voice = host.registry.preferences.contains { $0.id == BuiltinCatalog.voice && $0.enabled }
        let tray = host.registry.preferences.contains { $0.id == BuiltinCatalog.screenshots && $0.enabled }
        guard let layout = PanelSizeLayout(settings: config, screen: screen, edge: host.configuration.edge,
                                           content: content, voice: voice, tray: tray, floating: floating) else {
            hasPlacement = false; hide(); return
        }
        let form = layout.form
        var r = layout.frame, referenceHeight = layout.referenceHeight
        if form == .full { temporarilyExpanded = false }
        display.sizeForm = form
        if temporarilyExpanded {
            // Grow the existing panel on its own display. The override never enters the
            // configuration store, layout journal, workspace provider or management service.
            let factory = DisplaySettings()
            let safe = screen.visibleFrame
            func expanded(ignoring insets: [DisplayMetric]) -> (frame: SurfaceRect, fits: Bool)? {
                var open = config
                for inset in insets { open.measures[inset] = nil }
                open.measures[.panelWidth] = .init(max(r.width, factory.points(.panelWidth, in: safe.width)))
                open.measures[.panelHeight] = .init(max(r.height, factory.points(.panelHeight, in: safe.height)))
                guard var frame = open.panel(on: screen, fallbackEdge: host.configuration.edge, floating: floating) else { return nil }
                let limit = open.panelExtentRange(for: .panelWidth, on: screen).upperBound
                func fits(_ frame: SurfaceRect) -> Bool {
                    open.sizeForm(width: frame.width, height: max(1, frame.height - PanelSizeMetrics.minimumSide),
                                  content: content, voice: voice, tray: tray, temporarilyExpanded: true) == .full
                }
                while !fits(frame) && frame.width < limit {
                    open.measures[.panelWidth] = .init(min(limit, frame.width * 1.5))
                    guard let next = open.panel(on: screen, fallbackEdge: host.configuration.edge, floating: floating),
                          next.width > frame.width else { break }
                    frame = next
                }
                return (frame, fits(frame))
            }
            if var opening = expanded(ignoring: []) {
                // Committed margins can leave only an icon even on a large display.
                // Relax them only in the temporary surface and only when that makes the controls fit.
                let horizontal: [DisplayMetric] = [.sideInset].filter { config.points($0, in: safe.width) > 0 }
                let vertical: [DisplayMetric] = [.topInset, .bottomInset].filter { config.points($0, in: safe.height) > 0 }
                if !opening.fits {
                    var options = [horizontal, vertical].filter { !$0.isEmpty }
                    if options.count == 2 { options.append(horizontal + vertical) }
                    for margins in options {
                        if let candidate = expanded(ignoring: margins), candidate.fits {
                            opening = candidate
                            break
                        }
                    }
                }
                r = opening.frame
                referenceHeight = max(1, r.height - PanelSizeMetrics.minimumSide)
            }
        }
        display.referenceHeight = referenceHeight
        updateControls(form: form)
        #if canImport(SaytileVoiceUI)
        material.isHidden = !folded
        #endif
        if let panel = window as? EdgePanel {
            let safe = screen.visibleFrame
            panel.floatBounds = floating && !temporarilyExpanded ? NSRect(x:safe.x,y:safe.y,width:safe.width,height:safe.height) : nil
            let generation = placementGeneration
            panel.floatMoved = { [weak self] point in
                guard let self, generation == placementGeneration, hasPlacement, !temporarilyExpanded,
                      host.isRunning, !host.configuration.surfaceHidden, !captureSuppressed,
                      placement?.screen == screen, screen.id != primary,
                      host.configuration.displays[screen.id]?.placement == .floating else { return }
                var next = host.configuration.displays[screen.id] ?? .init()
                next.floatingPosition = .init(x:point.x,y:point.y)
                host.setDisplaySettings(next,id:screen.id)
            }
        }
        let frame = NSRect(x:r.x, y:r.y, width:r.width, height:r.height)
        // AppKit can round a fractional point when placing an NSPanel. Remember both values:
        // repeating the same request every observation tick would keep resizing that panel.
        if (window as? EdgePanel)?.draggingFloating != true && (requestedFrame != frame || window?.frame != placedFrame) {
            window?.setFrame(frame,display:false)
            requestedFrame = frame
            placedFrame = window?.frame
        }
        hasPlacement = true
    }

    @objc func toggleTemporaryExpansion() {
        guard presentationAllowed, !host.configuration.surfaceHidden, !captureSuppressed,
              hasPlacement, let placement, display.sizeForm != .full else { return }
        temporarilyExpanded.toggle()
        place(on: placement.screen, primary: placement.primary, content: placement.content)
    }

    private func updateControls(form: PanelSizeForm) {
        let shouldFold = form != .full && !temporarilyExpanded
        if shouldFold && foldedView == nil {
            let view = FoldedHostingView(rootView: FoldedSurfaceButton(modules: modules, display: display) { [weak self] in
                self?.toggleTemporaryExpansion()
            })
            view.sizingOptions = []
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor), view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor), view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
            foldedView = view
        }
        if temporarilyExpanded && closeExpansion == nil {
            let close = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)!,
                                 target: self, action: #selector(toggleTemporaryExpansion))
            close.isBordered = false
            close.toolTip = "收起 Nearpane"
            close.setAccessibilityLabel("收起 Nearpane")
            close.setAccessibilityIdentifier("nearpane-close-panel")
            close.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(close)
            NSLayoutConstraint.activate([
                close.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                close.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                close.widthAnchor.constraint(equalToConstant: PanelSizeMetrics.minimumSide),
                close.heightAnchor.constraint(equalToConstant: PanelSizeMetrics.minimumSide)
            ])
            closeExpansion = close
        }
        if shouldFold != folded {
            if shouldFold, let window, window.isKeyWindow {
                window.makeFirstResponder(nil)
                NSApp.deactivate()
            }
            folded = shouldFold
            container.wantsLayer = true
            container.layer?.cornerRadius = shouldFold ? DisplayMetric.cornerRadius.factory.value : 0
            container.layer?.masksToBounds = shouldFold
            if window?.isVisible == true { updateInteraction(hidden: folded) }
        }
        // Keep the same mounted module views, including the current text editor and draft.
        contentView.isHidden = shouldFold
        foldedView?.isHidden = !shouldFold
        closeExpansion?.isHidden = !temporarilyExpanded
        contentBottom.constant = temporarilyExpanded ? -PanelSizeMetrics.minimumSide : 0
    }

    private func updateInteraction(hidden: Bool) {
        guard interactionHidden != hidden else { return }
        interactionHidden = hidden
        display.interactionVisible = !hidden
        modules?.setInteractionHidden(hidden)
    }

    /// Never called by build scripts or tests. User launch is the only automatic presentation path.
    public func presentIfNeeded() {
        guard host.isRunning, hasPlacement, presentationAllowed, !captureSuppressed, !host.configuration.surfaceHidden else { hide(); return }
        updateInteraction(hidden: folded)
        if window?.isVisible == false { window?.orderFront(nil) }
    }
    public func hide() {
        (window as? EdgePanel)?.cancelFloatingDrag()
        updateInteraction(hidden: true)
        if window?.isVisible == true { window?.orderOut(nil) }
    }
}

@MainActor
public enum SystemScreens {
    public static func geometry() -> [ScreenGeometry] {
        // NSScreen.screens[0] is the menu-bar display, independent of the user's current key window.
        let raw: [ScreenGeometry?] = NSScreen.screens.map { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            guard let number, let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
            let id = CFUUIDCreateString(nil, uuid) as String
            return ScreenGeometry(id: id, frame: rect(screen.frame), visibleFrame: rect(screen.visibleFrame),
                                  rotationDegrees: CGDisplayRotation(number.uint32Value), backingScale: screen.backingScaleFactor)
        }
        return identifiedTopology(raw)
    }

    /// AppKit→Quartz coordinates depend on the original menu-bar screen's frame.
    /// Never promote the next display into that position when the first identity is missing.
    static func identifiedTopology(_ raw: [ScreenGeometry?]) -> [ScreenGeometry] {
        guard let first = raw.first ?? nil else { return [] }
        let screens = MultiDisplayPresentationCoordinator.identifiedScreens(raw.compactMap { $0 })
        return screens.first?.id == first.id ? screens : []
    }

    private static func rect(_ rect: NSRect) -> SurfaceRect {
        SurfaceRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }
}
