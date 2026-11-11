import AppKit
import SwiftUI
import NearpaneCore
#if canImport(NearpaneVoice)
import NearpaneVoice
import NearpaneTray
#endif

private final class ToolPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct ToolPresentation: Equatable {
    let display: String
    let presentationID: UUID?
    let expanded: FullscreenToolKind?
    let tools: [FullscreenToolKind]
}

/// Owns just the window. The Host controls fullscreen admission; Voice and Tray retain their lifetimes.
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

    public init(host: HostSession, domains: EmbeddedModules?) {
        self.host = host
        self.domains = domains
    }

    public func show(on screen: ScreenGeometry, expanded: FullscreenToolKind?, presentationID: UUID? = nil, confirmedControls: [SurfaceRect] = [],
                     permitInteraction: @escaping () -> Bool = { true },
                     open: @escaping (FullscreenToolKind) -> Void, close: @escaping () -> Void) {
        guard let cutouts = displayObstructions(on: screen) else { hide(); return }
        let obstructions = confirmedControls + cutouts
        let settings = host.configuration.displays[screen.id] ?? DisplaySettings()
        guard host.isRunning, !host.configuration.surfaceHidden, let domains else { hide(); return }
        let tools = FullscreenToolKind.allCases.filter { settings.fullscreenTools.allows($0) && available($0, domains) }
        guard expanded.map(tools.contains) ?? true,
              let frame = settings.fullscreenToolFrame(on: screen, expanded: expanded != nil, count: tools.count,
                                                       confirmedControls: obstructions) else { hide(); return }
        let next = ToolPresentation(display: screen.id, presentationID: presentationID, expanded: expanded, tools: tools)
        let panel = window ?? makePanel()
        window = panel
        requestOpen = open; requestClose = close; permitted = permitInteraction
        let geometryChanged = self.screen != screen || controls != obstructions
        self.screen = screen
        controls = obstructions
        if state != next || geometryChanged {
            state = next
            dragOrigin = nil
            generation = UUID()
            let binding = generation
            let view = FullscreenToolPanelView(domains: domains, state: next,
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
            panel.contentView = content
        }
        if dragOrigin == nil, panel.frame != frame.nsRect { panel.setFrame(frame.nsRect, display: true) }
        if !panel.isVisible { panel.orderFront(nil) }
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

    private func available(_ kind: FullscreenToolKind, _ modules: EmbeddedModules) -> Bool {
        #if canImport(NearpaneVoice)
        return kind == .voice ? modules.voice.active : modules.tray.active && modules.tray.connected && modules.tray.captureEntry
        #else
        return false
        #endif
    }

    private func isCurrent(_ binding: UUID) -> Bool {
        guard binding == generation, window?.isVisible == true, host.isRunning, !host.configuration.surfaceHidden,
              let state, let domains, permitted?() == true else { return false }
        let prefs = host.configuration.displays[state.display]?.fullscreenTools ?? .init()
        return state.tools.allSatisfy { prefs.allows($0) && available($0, domains) }
    }

    public func hide() {
        guard state != nil else { return }
        generation = UUID()
        window?.orderOut(nil)
        window?.contentView = nil
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
        panel.isMovable = false; panel.level = .floating
        panel.sharingType = .none
        panel.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces, .stationary, .ignoresCycle]
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
    let domains: EmbeddedModules, state: ToolPresentation
    let permit: @MainActor () -> Bool
    let open: (FullscreenToolKind) -> Void, close: () -> Void, move: (ToolMove) -> Void
    var body: some View {
        HStack(spacing: 0) {
            if let tool = state.expanded {
                ToolDragHandle(move: move).frame(width: 22, height: 28).help("拖动浮层")
                Spacer(minLength: 2)
                #if canImport(NearpaneVoice)
                if tool == .voice {
                    FullscreenVoiceButton(module: domains.voice, permit: permit)
                } else {
                    Button {
                        guard permit(), CGPreflightScreenCaptureAccess() else { return }
                        domains.tray.captureFromFullscreen()
                    } label: { Image(systemName: "camera").frame(width: 38, height: 28) }
                    .accessibilityLabel("系统截图").accessibilityIdentifier("np.fullscreen.capture")
                    .help("使用已有的屏幕录制权限进行系统截图")
                    .disabled(!domains.tray.captureEntry || !CGPreflightScreenCaptureAccess())
                }
                #endif
                Spacer(minLength: 2)
                Button(action: close) { Image(systemName: "xmark").frame(width: 24, height: 26) }
                    .help("收起浮层").accessibilityLabel("收起浮层").accessibilityIdentifier("np.fullscreen.close")
            } else {
                ForEach(state.tools, id: \.self) { tool in
                    let title = tool == .voice ? "打开语音工具" : "打开截图工具"
                    Button { open(tool) } label: {
                        Image(systemName: tool == .voice ? "mic" : "photo").frame(width: 24, height: 24)
                    }.help(title).accessibilityLabel(title).accessibilityIdentifier("np.fullscreen.open." + tool.rawValue)
                }
            }
        }.padding(.horizontal, 4).frame(maxWidth: .infinity, maxHeight: .infinity)
        .font(.system(size: 12)).buttonStyle(.plain)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
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
