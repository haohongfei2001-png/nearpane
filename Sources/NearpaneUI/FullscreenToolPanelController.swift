import AppKit
import SwiftUI
import NearpaneCore
#if canImport(NearpaneVoice)
import NearpaneVoice
import NearpaneTray
#endif

private final class ToolPanel: NSPanel {
    var permitInteraction: (() -> Bool)?
    var interactionInvalidated: (() -> Void)?
    private var editingWasRequested = false
    override var canBecomeKey: Bool { editingWasRequested && permitInteraction?() == true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type != .appKitDefined && event.type != .systemDefined && event.type != .applicationDefined {
            guard permitInteraction?() == true else { interactionInvalidated?(); return }
        }
        if event.type == .leftMouseDown, let content = contentView {
            var target = content.hitTest(content.convert(event.locationInWindow, from: nil))
            while let view = target {
                let editor = (view as? NSTextView).map { $0.isEditable } == true ||
                    (view as? NSTextField).map { $0.isEditable && $0.isEnabled } == true
                if editor {
                    editingWasRequested = true
                    makeKey(); makeFirstResponder(view)
                    break
                }
                target = view.superview
            }
        }
        super.sendEvent(event)
    }

    func withdrawEditing() {
        editingWasRequested = false
        makeFirstResponder(nil)
        if isKeyWindow { resignKey() }
    }
}

private struct ToolPresentation: Equatable {
    let display: String
    let presentationID: UUID?
    let expanded: FullscreenToolKind?
    let tools: [FullscreenToolKind]
}

/// Owns only a desktop presentation. All modules retain the Host's existing lifetimes.
@MainActor public final class FullscreenToolPanelController {
    private let host: HostSession
    private let domains: EmbeddedModules?
    public private(set) var window: NSPanel?
    private var state: ToolPresentation?
    private var screen: ScreenGeometry?
    private var controls: [SurfaceRect] = []
    private var generation = UUID()
    private var requestOpen: ((FullscreenToolKind) -> Void)?
    private var requestClose: (() -> Void)?
    private var permitted: (() -> Bool)?
    private var dragOrigin: SurfaceRect?
    private let display = SurfaceDisplay()
    private var material: PanelGlassMaterial?
    private var presentedLayout: SurfaceLayout?

    public init(host: HostSession, domains: EmbeddedModules?) {
        self.host = host
        self.domains = domains
    }

    public func show(on screen: ScreenGeometry, expanded: FullscreenToolKind?, presentationID: UUID? = nil, confirmedControls: [SurfaceRect] = [],
                     permitInteraction: @escaping () -> Bool = { true },
                     open: @escaping (FullscreenToolKind) -> Void, close: @escaping () -> Void) {
        guard let cutouts = displayObstructions(on: screen) else { hide(); return }
        let obstructions = confirmedControls + cutouts
        let settings = host.panelPresentationSettings(on: screen.id)
        guard host.isRunning, !host.configuration.surfaceHidden, let domains, permitInteraction(),
              let workspace = workspace(on: screen, settings: settings, domains: domains),
              let frame = settings.fullscreenToolFrame(on: screen, expanded: expanded != nil, count: 1,
                  confirmedControls: obstructions, workspace: workspace) else { hide(); return }
        let next = ToolPresentation(display: screen.id, presentationID: presentationID,
                                    expanded: expanded == nil ? nil : .workspace, tools: [.workspace])
        let panel = window ?? makePanel()
        window = panel
        requestOpen = open; requestClose = close; permitted = permitInteraction
        let geometryChanged = self.screen != screen || controls != obstructions
        self.screen = screen
        controls = obstructions
        display.id = screen.id; display.primaryID = screen.id
        display.referenceHeight = screen.visibleFrame.height
        display.content = .toolsOnly; display.secondary = false; display.sizeForm = .full
        if state != next || geometryChanged {
            state = next
            dragOrigin = nil
            generation = UUID()
            let binding = generation
            let view = FullscreenToolPanelView(host: host, domains: domains, state: next, display: display,
                permit: { [weak self] in self?.isCurrent(binding) == true },
                open: { [weak self] tool in
                    guard let self, isCurrent(binding) else { return }
                    requestOpen?(tool)
                }, close: { [weak self] in
                    guard let self, isCurrent(binding) else { return }
                    requestClose?()
                }, move: { [weak self] gesture in
                    guard let self, isCurrent(binding) else { return }
                    move(gesture)
                })
            let content = ToolHostingView(rootView: view)
            content.sizingOptions = []
            content.translatesAutoresizingMaskIntoConstraints = false
            let container = NSView()
            container.wantsLayer = true
            container.layer?.cornerCurve = .continuous
            container.layer?.cornerRadius = next.expanded == nil ? 9 : 12
            container.layer?.masksToBounds = true
            if next.expanded != nil {
                let backdrop = PanelGlassMaterial(frame: .zero)
                backdrop.material = .popover
                backdrop.blendingMode = .behindWindow
                backdrop.state = .active
                material = backdrop
                backdrop.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(backdrop)
                NSLayoutConstraint.activate([
                    backdrop.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    backdrop.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                    backdrop.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                    backdrop.topAnchor.constraint(equalTo: container.topAnchor, constant: -FullscreenWorkspaceLayout.headerHeight)
                ])
                presentedLayout = workspace.content
                display.updateMaterial = { [weak self, weak backdrop] layout in
                    guard let self, let backdrop, binding == generation, state?.expanded != nil else { return }
                    presentedLayout = layout
                    backdrop.configure(size: backdrop.bounds.size, layout: layout,
                                       settings: host.panelPresentationSettings(on: next.display))
                }
            } else {
                material = nil; presentedLayout = nil; display.updateMaterial = nil
            }
            container.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                content.topAnchor.constraint(equalTo: container.topAnchor),
                content.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
            panel.contentView = container
            if let panel = panel as? ToolPanel {
                panel.withdrawEditing()
                panel.permitInteraction = { [weak self] in self?.isCurrent(binding) == true }
                panel.interactionInvalidated = { [weak self] in self?.hide() }
            }
        }
        if dragOrigin == nil, panel.frame != frame.nsRect { panel.setFrame(frame.nsRect, display: true) }
        panel.contentView?.layoutSubtreeIfNeeded()
        if let material {
            material.configure(size: material.bounds.size, layout: presentedLayout ?? workspace.content, settings: settings)
        }
        if !panel.isVisible { panel.orderFront(nil) }
        display.interactionVisible = panel.isVisible
        domains.setFullscreenInteractionVisible(panel.isVisible && next.expanded != nil)
    }

    /// The display's own insets and unobscured wings are public geometry. Avoid the actual
    /// camera area when available; never inspect the fullscreen application's view tree.
    private func displayObstructions(on screen: ScreenGeometry) -> [SurfaceRect]? {
        guard let match = NSScreen.screens.first(where: { candidate in
            guard candidate.frame == screen.frame.nsRect,
                  let n = candidate.deviceDescription[.init("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue() else { return false }
            return CFUUIDCreateString(nil, uuid) as String == screen.id
        }) else { return nil }
        let frame = match.frame, inset = match.safeAreaInsets
        var rectangles = [
            CGRect(x: frame.minX, y: frame.minY, width: inset.left, height: frame.height),
            CGRect(x: frame.maxX - inset.right, y: frame.minY, width: inset.right, height: frame.height),
            CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: inset.bottom)
        ]
        if inset.top > 0 {
            let top = CGRect(x: frame.minX, y: frame.maxY - inset.top, width: frame.width, height: inset.top)
            if let left = match.auxiliaryTopLeftArea, let right = match.auxiliaryTopRightArea,
               !left.isEmpty, !right.isEmpty, frame.contains(left), frame.contains(right),
               left.maxX < right.minX, left.minY <= top.minY, right.minY <= top.minY,
               left.maxY >= top.maxY, right.maxY >= top.maxY {
                rectangles.append(CGRect(x: left.maxX, y: top.minY, width: right.minX - left.maxX, height: top.height))
            } else { rectangles.append(top) }
        }
        return rectangles.filter { !$0.isEmpty }.map(SurfaceRect.init)
    }

    private func workspace(on screen: ScreenGeometry, settings: DisplaySettings, domains: EmbeddedModules) -> FullscreenWorkspaceLayout? {
        FullscreenWorkspaceLayout(on: screen, settings: settings,
            enabledModuleIDs: host.registry.preferences.filter(\.enabled).map(\.id),
            pinnedCount: host.registry.pinnedModules.count, expandedSample: host.registry.expandedID != nil,
            voiceCompact: domains.voiceCompact, trayRows: domains.trayRowCount, lyricsHeight: domains.lyricsHeight)
    }

    private func isCurrent(_ binding: UUID) -> Bool {
        guard binding == generation, window?.isVisible == true, host.isRunning, !host.configuration.surfaceHidden,
              let state, let screen, let domains, permitted?() == true else { return false }
        let prefs = host.configuration.displays[state.display]?.fullscreenTools ?? .init()
        return prefs.enabled && workspace(on: screen, settings: host.panelPresentationSettings(on: state.display), domains: domains) != nil
    }

    public func hide() {
        guard state != nil else { return }
        generation = UUID()
        display.interactionVisible = false; display.updateMaterial = nil
        domains?.setFullscreenInteractionVisible(false)
        (window as? ToolPanel)?.withdrawEditing()
        window?.orderOut(nil)
        window?.contentView = nil
        material = nil; presentedLayout = nil
        state = nil; screen = nil; controls = []; dragOrigin = nil
        requestOpen = nil; requestClose = nil; permitted = nil
    }

    private func makePanel() -> NSPanel {
        let panel = ToolPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                              backing: .buffered, defer: true)
        panel.identifier = NSUserInterfaceItemIdentifier("np.fullscreen.panel")
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.isMovable = false; panel.level = .floating
        panel.sharingType = .none
        panel.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces, .transient, .ignoresCycle]
        return panel
    }

    private func move(_ gesture: ToolMove) {
        guard let screen, let window, state?.expanded != nil else { return }
        let current = SurfaceRect(window.frame)
        switch gesture {
        case .begin: dragOrigin = current
        case let .offset(x, y, commit):
            var proposed = dragOrigin ?? current
            proposed.x += x; proposed.y += y
            guard let placed = FloatingToolSurface(anchor: proposed).placement(safe: screen.visibleFrame, confirmedControls: controls)
            else { dragOrigin = nil; return }
            window.setFrame(placed.nsRect, display: true)
            if commit {
                dragOrigin = nil
                var settings = host.configuration.displays[screen.id] ?? DisplaySettings()
                settings.saveFullscreenToolFrame(placed, on: screen)
                host.setDisplaySettings(settings, id: screen.id)
            }
        }
    }
}

private extension SurfaceRect {
    init(_ rect: CGRect) { self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height) }
    var nsRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

private enum ToolMove {
    case begin
    case offset(Double, Double, commit: Bool)
}

private final class ToolHostingView: NSHostingView<FullscreenToolPanelView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { false }
}

private struct FullscreenToolPanelView: View {
    let host: HostSession
    let domains: EmbeddedModules, state: ToolPresentation
    let display: SurfaceDisplay
    let permit: @MainActor () -> Bool
    let open: (FullscreenToolKind) -> Void, close: () -> Void, move: (ToolMove) -> Void
    var body: some View {
        Group {
            if state.expanded != nil {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        ToolDragHandle(move: move).frame(width: 22, height: 28).help("拖动浮层")
                        Text("工具").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Button { if permit() { close() } } label: {
                            Image(systemName: "xmark").font(.system(size: 11, weight: .medium)).frame(width: 28, height: 28)
                        }.buttonStyle(.plain).help("收起浮层")
                            .accessibilityLabel("收起浮层").accessibilityIdentifier("np.fullscreen.close")
                    }.padding(.horizontal, 6).frame(height: FullscreenWorkspaceLayout.headerHeight)
                        .background(.regularMaterial)
                    EdgeSurfaceView(host: host, modules: domains, display: display)
                        .accessibilityIdentifier("np.fullscreen.workspace")
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                Button { if permit() { open(.workspace) } } label: {
                    Label("打开工具", systemImage: "rectangle.stack")
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                }.buttonStyle(.plain).help("打开已启用的工具")
                    .accessibilityIdentifier("np.fullscreen.open.workspace")
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(!display.interactionVisible)
        .productAccent(host.configuration.accent)
    }
}

private struct ToolDragHandle: NSViewRepresentable {
    let move: (ToolMove) -> Void
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) { view.move = move }

    final class DragView: NSView {
        var move: ((ToolMove) -> Void)?
        private var origin: NSPoint?
        override var needsPanelToBecomeKey: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(true)
            setAccessibilityRole(.slider)
            setAccessibilityLabel("移动浮层")
            setAccessibilityIdentifier("np.fullscreen.move")
        }
        required init?(coder: NSCoder) { nil }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.secondaryLabelColor.setFill()
            for x in [-2.5, 2.5] {
                for y in [-5.0, 0.0, 5.0] {
                    NSBezierPath(ovalIn: NSRect(x: bounds.midX+x-1, y: bounds.midY+y-1, width: 2, height: 2)).fill()
                }
            }
        }
        override func mouseDown(with event: NSEvent) {
            origin = window?.convertPoint(toScreen: event.locationInWindow)
            move?(.begin)
        }
        private func sendOffset(_ event: NSEvent, commit: Bool) {
            guard let origin, let point = window?.convertPoint(toScreen: event.locationInWindow) else { return }
            move?(.offset(point.x-origin.x, point.y-origin.y, commit: commit))
            if commit { self.origin = nil }
        }
        override func mouseDragged(with event: NSEvent) { sendOffset(event, commit: false) }
        override func mouseUp(with event: NSEvent) { sendOffset(event, commit: true) }
        override func accessibilityPerformIncrement() -> Bool { move?(.offset(16, 0, commit: true)); return true }
        override func accessibilityPerformDecrement() -> Bool { move?(.offset(-16, 0, commit: true)); return true }
        override func accessibilityIsIgnored() -> Bool { false }
    }
}
