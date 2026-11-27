import AppKit
import Combine
import Foundation
import SwiftUI
import TileKit

@MainActor
public final class LyricPanelController: NSObject, NSWindowDelegate {
    public let panel: NSPanel
    public private(set) var slotFrame: NSRect = .zero
    public private(set) var displayUUID: String?
    public private(set) var placementPermitted = true
    /// Fired after an explicit drag or completed placement, never on every mouse frame.
    public var placementDidChange: (@MainActor (NSRect, String?, Bool) -> Void)?
    public var usesCoordinatedPlacement = false
    /// Playback intent is separate from registry permission and window occlusion.
    public private(set) var wantsPresentation = false
    public var visibilityIntentDidChange: (@MainActor (Bool) -> Void)?
    public var contentHeightDidChange: (@MainActor (CGFloat, Bool) -> Void)?
    public var contentHeight: CGFloat {
        model.panelContent == .lyrics ? LyricPanelLayout.lyricsHeight : LyricPanelLayout.compactHeight
    }
    private let model: LyricAppModel
    private let defaults: UserDefaults
    private var subscriptions: Set<AnyCancellable> = []
    private var dragging = false
    private var visibilityPolicy = LyricPanelVisibilityPolicy()
    private var userHidden = false
    private var surrendered = false
    private var saved: [String: SavedPlacement]
    private var lastRequestedHeight: CGFloat = LyricPanelLayout.compactHeight
    private var lastContractionDeferred = false

    private struct SavedPlacement: Codable {
        var horizontalFraction: Double
        var verticalFractionFromTop: Double
    }

    public init(model: LyricAppModel, defaults: UserDefaults = .standard) {
        self.model = model; self.defaults = defaults
        saved = defaults.data(forKey: "LyricTile.placement.v1")
            .flatMap { try? JSONDecoder().decode([String: SavedPlacement].self, from: $0) } ?? [:]
        let panel = LyricNonactivatingPanel(contentRect: NSRect(x: 0, y: 0, width: 208, height: LyricPanelLayout.maximumHeight),
                                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.panel = panel
        super.init()
        panel.delegate = self
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true; panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating; panel.isMovableByWindowBackground = false
        panel.title = "LyricTile"
        panel.setAccessibilityLabel("LyricTile 歌词板")
        let hosting = NSHostingView(rootView: LyricPanelView(model: model))
        let container = LyricPanelContainer(hosting: hosting, onDragBegin: { [weak self] in
            self?.dragging = true
        }, onDragEnd: { [weak self] point in self?.finishedDragging(at: point) })
        panel.contentView = container
        applyWindowSettings(model.settings)
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        model.$snapshot.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshForPlayback() }
        }.store(in: &subscriptions)
        model.$settings.sink { [weak self] settings in
            self?.applyWindowSettings(settings)
            Task { @MainActor [weak self] in self?.refreshForPlayback() }
        }.store(in: &subscriptions)
        // A lyric response can arrive between player polls. Resize on its own
        // publication; controls also determine whether a paused panel can remain.
        model.$frame.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshForPlayback() }
        }.store(in: &subscriptions)
        model.$document.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshForPlayback() }
        }.store(in: &subscriptions)
        model.$browsedCueIndex.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshForPlayback() }
        }.store(in: &subscriptions)
        model.$panelInteractionActive.combineLatest(model.$songMenuIsOpen, model.$seekPreviewMS)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshForPlayback() }
            }.store(in: &subscriptions)
        restorePosition(reset: false)
    }

    public var windowIDs: [Int] { panel.windowNumber > 0 ? [panel.windowNumber] : [] }
    public func show(userInitiated: Bool = false) {
        if userInitiated { userHidden = false }
        updateVisibilityIntent()
        guard wantsPresentation, placementPermitted else { return }
        if slotFrame == .zero { restorePosition(reset: false) }
        guard slotFrame != .zero else { return }
        guard !usesCoordinatedPlacement || contentHeight <= slotFrame.height else { return }
        resizeVisibleSurface()
        if !panel.isVisible { panel.orderFrontRegardless() }
        model.isVisible = panel.occlusionState.contains(.visible)
    }
    public func hide(userInitiated: Bool = false) {
        if userInitiated { userHidden = true }
        withdraw()
        updateVisibilityIntent()
    }
    /// Stops input and removes the old panel before session ownership is released.
    public func surrender() {
        surrendered = true
        panel.ignoresMouseEvents = true
        withdraw()
        updateVisibilityIntent()
    }
    public func resumePresentation() {
        surrendered = false; panel.ignoresMouseEvents = false; userHidden = false
        updateVisibilityIntent()
    }
    /// A pending TileKit withdrawal barrier must not be bypassed by a playback update.
    public func setPlacementPermission(_ permitted: Bool) {
        placementPermitted = permitted
        if !permitted { withdraw() }
    }
    public func withdraw() {
        dragging = false
        panel.orderOut(nil)
        model.isVisible = false
        model.cancelSeek()
        if model.panelInteractionActive { model.panelInteractionActive = false }
        model.setControlsVisible(false)
    }
    /// Root's TileKit transaction may call this only while withdrawn, then present after its barrier.
    public func placeHidden(slot: NSRect, displayUUID: String?) {
        guard !panel.isVisible else { return }
        slotFrame = slot; self.displayUUID = displayUUID
        resizeVisibleSurface()
    }
    public func restorePosition(reset: Bool) {
        let screens = LyricScreenIdentity.screens
        let preferred = reset ? model.settings.preferredDisplayUUID : displayUUID ?? model.settings.preferredDisplayUUID
        let selected = screens.first(where: { $0.id == preferred })
            ?? screens.first(where: { $0.screen === NSScreen.main })
            ?? screens.sorted(by: { $0.id < $1.id }).first
        guard let selected else { withdraw(); return }
        let visible = selected.screen.visibleFrame
        let width = TileGeometry.standaloneWidth(visibleWidth: visible.width)
        guard visible.width >= width + 32, visible.height >= LyricPanelLayout.maximumHeight + 32 else {
            withdraw(); model.actionMessage = "这个显示器的可用空间不足，请在设置中选择其他显示器。"; return
        }
        let stored = reset ? nil : saved[selected.id]
        let x = stored.map { visible.minX + 16 + (visible.width - width - 32) * min(1, max(0, $0.horizontalFraction)) }
            ?? (visible.maxX - width - 16)
        let y = stored.map { visible.maxY - 16 - LyricPanelLayout.maximumHeight - (visible.height - LyricPanelLayout.maximumHeight - 32) * min(1, max(0, $0.verticalFractionFromTop)) }
            ?? (visible.maxY - LyricPanelLayout.maximumHeight - 16)
        slotFrame = NSRect(x: x.rounded(), y: y.rounded(), width: width, height: LyricPanelLayout.maximumHeight)
        displayUUID = selected.id
        resizeVisibleSurface()
        if reset { saveCurrentPosition() }
        placementDidChange?(slotFrame, displayUUID, reset)
    }
    public func windowDidChangeOcclusionState(_ notification: Notification) {
        model.isVisible = panel.isVisible && panel.occlusionState.contains(.visible) && !surrendered
    }
    public func windowDidResignKey(_ notification: Notification) {
        (panel as? LyricNonactivatingPanel)?.permitsKeyInteraction = false
    }
    private func refreshForPlayback() {
        updateVisibilityIntent()
        let height = contentHeight
        let deferred = model.isRetainingPausedSurface
        if height != lastRequestedHeight || deferred != lastContractionDeferred {
            lastRequestedHeight = height
            lastContractionDeferred = deferred
            contentHeightDidChange?(height, deferred)
        }
        guard wantsPresentation, placementPermitted else { withdraw(); return }
        show()
    }
    private func updateVisibilityIntent() {
        let interacting = dragging || model.panelInteractionActive || model.songMenuIsOpen
            || model.seekPreviewMS != nil
        let playingOrRetained = visibilityPolicy.shouldPresent(model.snapshot,
            wasVisible: panel.isVisible, isInteracting: interacting)
        let desired = model.ownsSession && !surrendered && !userHidden && playingOrRetained
        guard desired != wantsPresentation else { return }
        wantsPresentation = desired
        visibilityIntentDidChange?(desired)
    }
    private func resizeVisibleSurface() {
        guard !dragging, slotFrame != .zero else { return }
        let height = contentHeight
        // Content can change before the coordinator has committed its new plan.
        // Growing beyond the current grant would overlap a neighbouring tool.
        guard !usesCoordinatedPlacement || height <= slotFrame.height else { return }
        let frame = NSRect(x: slotFrame.minX, y: slotFrame.maxY - height, width: slotFrame.width, height: height)
        if panel.frame != frame { panel.setFrame(frame, display: true, animate: false) }
    }
    private func applyWindowSettings(_ settings: LyricSettings) {
        switch settings.appearance {
        case .automatic: panel.appearance = nil
        case .light: panel.appearance = NSAppearance(named: .aqua)
        case .dark: panel.appearance = NSAppearance(named: .darkAqua)
        }
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        behavior.insert(settings.showInFullScreen ? .fullScreenAuxiliary : .fullScreenNone)
        panel.collectionBehavior = behavior
    }
    private func finishedDragging(at point: NSPoint) {
        guard dragging else { return }
        dragging = false
        guard !surrendered, placementPermitted, panel.isVisible,
              let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? panel.screen else { return }
        let visible = screen.visibleFrame
        let width = TileGeometry.standaloneWidth(visibleWidth: visible.width)
        guard visible.width >= width + 32, visible.height >= LyricPanelLayout.maximumHeight + 32 else { restorePosition(reset: false); return }
        // A drag proposes a column order/display. The coordinator commits the final slot.
        let x = visible.maxX - width - 16
        let top = min(visible.maxY - 16, max(visible.minY + LyricPanelLayout.maximumHeight + 16, panel.frame.maxY))
        slotFrame = NSRect(x: x.rounded(), y: (top - LyricPanelLayout.maximumHeight).rounded(), width: width, height: LyricPanelLayout.maximumHeight)
        displayUUID = LyricScreenIdentity.id(for: screen)
        if usesCoordinatedPlacement { setPlacementPermission(false) }
        else { resizeVisibleSurface() }
        model.settings.preferredDisplayUUID = displayUUID
        saveCurrentPosition()
        placementDidChange?(slotFrame, displayUUID, true)
    }
    private func saveCurrentPosition() {
        guard let displayUUID, let screen = LyricScreenIdentity.screens.first(where: { $0.id == displayUUID })?.screen else { return }
        let visible = screen.visibleFrame
        saved[displayUUID] = SavedPlacement(horizontalFraction: (slotFrame.minX - visible.minX - 16) / max(1, visible.width - slotFrame.width - 32),
                                           verticalFractionFromTop: (visible.maxY - 16 - slotFrame.maxY) / max(1, visible.height - LyricPanelLayout.maximumHeight - 32))
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: "LyricTile.placement.v1") }
    }
    @objc private func displaysChanged() {
        if usesCoordinatedPlacement {
            withdraw()
            placementDidChange?(slotFrame, displayUUID, false)
            return
        }
        let wasVisible = panel.isVisible
        withdraw(); restorePosition(reset: false)
        if wasVisible { show() }
    }
    @objc private func didWake() {
        guard model.ownsSession else { return }
        displaysChanged()
        model.reconnect()
    }
}

@MainActor
private final class LyricNonactivatingPanel: NSPanel {
    var permitsKeyInteraction = false
    override var canBecomeKey: Bool { permitsKeyInteraction }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown { permitsKeyInteraction = true }
        super.sendEvent(event)
    }
}

@MainActor
private final class LyricPanelContainer: NSView {
    private let hosting: NSView
    private let drag: LyricDragStrip
    override var isFlipped: Bool { true }
    init(hosting: NSView, onDragBegin: @escaping @MainActor () -> Void, onDragEnd: @escaping @MainActor (NSPoint) -> Void) {
        self.hosting = hosting; drag = LyricDragStrip(onBegin: onDragBegin, onEnd: onDragEnd)
        super.init(frame: .zero)
        addSubview(hosting); addSubview(drag)
    }
    required init?(coder: NSCoder) { return nil }
    override func layout() {
        super.layout()
        hosting.frame = bounds
        drag.frame = NSRect(x: 22, y: 0, width: max(0, bounds.width - 44), height: 10)
    }
}
@MainActor
private final class LyricDragStrip: NSView {
    let onBegin: @MainActor () -> Void
    let onEnd: @MainActor (NSPoint) -> Void
    private var offset = NSPoint.zero
    private var tracking = false
    init(onBegin: @escaping @MainActor () -> Void, onEnd: @escaping @MainActor (NSPoint) -> Void) {
        self.onBegin = onBegin; self.onEnd = onEnd
        super.init(frame: .zero)
        toolTip = "拖动以调整右侧列顺序，或移到另一显示器"
    }
    required init?(coder: NSCoder) { return nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {
        offset = event.locationInWindow
        tracking = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window, window.isVisible else { return }
        if !tracking { tracking = true; onBegin() }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        window.setFrameOrigin(NSPoint(x: point.x - offset.x, y: point.y - offset.y))
    }
    override func mouseUp(with event: NSEvent) {
        guard tracking, let window else { return }
        tracking = false
        onEnd(window.convertPoint(toScreen: event.locationInWindow))
    }
}
