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
    private let model: LyricAppModel
    private let defaults: UserDefaults
    private var subscriptions: Set<AnyCancellable> = []
    private var dragTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var hideRevision: UInt64 = 0
    private var userHidden = false
    private var surrendered = false
    private var saved: [String: SavedPlacement]

    private struct SavedPlacement: Codable {
        var horizontalFraction: Double
        var verticalFractionFromTop: Double
    }

    public init(model: LyricAppModel, defaults: UserDefaults = .standard) {
        self.model = model; self.defaults = defaults
        saved = defaults.data(forKey: "LyricTile.placement.v1")
            .flatMap { try? JSONDecoder().decode([String: SavedPlacement].self, from: $0) } ?? [:]
        let panel = LyricNonactivatingPanel(contentRect: NSRect(x: 0, y: 0, width: 208, height: 272),
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
        let container = LyricPanelContainer(hosting: hosting, onDragBegin: { [weak self] in self?.beganDragging() })
        panel.contentView = container
        applyCollectionBehavior(model.settings)
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        model.$snapshot.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshForPlayback() }
        }.store(in: &subscriptions)
        model.$settings.sink { [weak self] settings in
            self?.applyCollectionBehavior(settings)
            Task { @MainActor [weak self] in self?.refreshForPlayback() }
        }.store(in: &subscriptions)
        restorePosition(reset: false)
    }

    public var windowIDs: [Int] { panel.windowNumber > 0 ? [panel.windowNumber] : [] }
    public func show(userInitiated: Bool = false) {
        guard model.ownsSession, !surrendered, placementPermitted else { return }
        if userInitiated { userHidden = false; cancelIdleHide() }
        guard !userHidden else { return }
        if slotFrame == .zero { restorePosition(reset: false) }
        guard slotFrame != .zero else { return }
        resizeVisibleSurface()
        if !panel.isVisible { panel.orderFrontRegardless() }
        model.isVisible = panel.occlusionState.contains(.visible)
        if model.idle {
            if model.settings.hideWhenIdle { scheduleIdleHide() }
            else { cancelIdleHide() }
        }
    }
    public func hide(userInitiated: Bool = false) {
        if userInitiated { userHidden = true }
        withdraw()
    }
    /// Stops input and removes the old panel before session ownership is released.
    public func surrender() {
        surrendered = true
        cancelIdleHide()
        panel.ignoresMouseEvents = true
        withdraw()
    }
    public func resumePresentation() { surrendered = false; panel.ignoresMouseEvents = false; userHidden = false }
    /// A pending TileKit withdrawal barrier must not be bypassed by a playback update.
    public func setPlacementPermission(_ permitted: Bool) {
        placementPermitted = permitted
        if !permitted { withdraw() }
    }
    public func withdraw() {
        dragTask?.cancel(); dragTask = nil
        panel.orderOut(nil)
        model.isVisible = false
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
        guard visible.width >= width + 32, visible.height >= 304 else {
            withdraw(); model.actionMessage = "这个显示器的可用空间不足，请在设置中选择其他显示器。"; return
        }
        let stored = reset ? nil : saved[selected.id]
        let x = stored.map { visible.minX + 16 + (visible.width - width - 32) * min(1, max(0, $0.horizontalFraction)) }
            ?? (visible.maxX - width - 16)
        let y = stored.map { visible.maxY - 16 - 272 - (visible.height - 272 - 32) * min(1, max(0, $0.verticalFractionFromTop)) }
            ?? (visible.maxY - 272 - 16)
        slotFrame = NSRect(x: x.rounded(), y: y.rounded(), width: width, height: 272)
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
        guard model.ownsSession, !surrendered, placementPermitted else { withdraw(); return }
        resizeVisibleSurface()
        if model.idle {
            if model.settings.hideWhenIdle { scheduleIdleHide() }
            else { cancelIdleHide(); if !userHidden { show() } }
        } else { cancelIdleHide(); show() }
    }
    private func resizeVisibleSurface() {
        guard dragTask == nil, slotFrame != .zero else { return }
        let height: CGFloat = model.idle && model.ownershipMessage == nil ? 62 : 272
        let frame = NSRect(x: slotFrame.minX, y: slotFrame.maxY - height, width: slotFrame.width, height: height)
        if panel.frame != frame { panel.setFrame(frame, display: true, animate: false) }
    }
    private func scheduleIdleHide() {
        guard dragTask == nil, model.settings.hideWhenIdle, hideTask == nil else { return }
        hideRevision &+= 1
        let expected = hideRevision
        hideTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) }
            catch {
                if let self, self.hideRevision == expected { self.hideTask = nil }
                return
            }
            guard let self, self.hideRevision == expected else { return }
            self.hideTask = nil
            guard self.model.idle, self.model.settings.hideWhenIdle else { return }
            self.withdraw()
        }
    }
    private func cancelIdleHide() {
        hideRevision &+= 1
        hideTask?.cancel(); hideTask = nil
    }
    private func applyCollectionBehavior(_ settings: LyricSettings) {
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        behavior.insert(settings.showInFullScreen ? .fullScreenAuxiliary : .fullScreenNone)
        panel.collectionBehavior = behavior
    }
    private func beganDragging() {
        cancelIdleHide()
        dragTask?.cancel()
        // performDrag returns immediately and AppKit may withhold mouseUp while
        // WindowServer owns the drag. Keep playback updates off the moving frame.
        dragTask = Task { @MainActor [weak self] in
            repeat {
                do { try await Task.sleep(for: .milliseconds(32)) } catch { return }
            } while NSEvent.pressedMouseButtons & 1 != 0
            guard let self, !Task.isCancelled else { return }
            self.dragTask = nil
            guard self.panel.isVisible, self.model.ownsSession, self.placementPermitted else { return }
            self.finishedDragging()
            if self.model.idle && self.model.settings.hideWhenIdle { self.scheduleIdleHide() }
        }
    }
    private func finishedDragging() {
        guard !surrendered, let screen = panel.screen else { return }
        let visible = screen.visibleFrame
        let width = TileGeometry.standaloneWidth(visibleWidth: visible.width)
        guard visible.width >= width + 32, visible.height >= 304 else { restorePosition(reset: false); return }
        // A drag proposes a column order/display. The coordinator commits the final slot.
        let x = visible.maxX - width - 16
        let top = min(visible.maxY - 16, max(visible.minY + 272 + 16, panel.frame.maxY))
        slotFrame = NSRect(x: x.rounded(), y: (top - 272).rounded(), width: width, height: 272)
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
                                           verticalFractionFromTop: (visible.maxY - 16 - slotFrame.maxY) / max(1, visible.height - 272 - 32))
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
    init(hosting: NSView, onDragBegin: @escaping @MainActor () -> Void) {
        self.hosting = hosting; drag = LyricDragStrip(onBegin: onDragBegin)
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
    init(onBegin: @escaping @MainActor () -> Void) {
        self.onBegin = onBegin; super.init(frame: .zero)
        toolTip = "拖动以调整右侧列顺序，或移到另一显示器"
    }
    required init?(coder: NSCoder) { return nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onBegin(); window?.performDrag(with: event) }
}
