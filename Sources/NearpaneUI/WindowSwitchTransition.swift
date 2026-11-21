import AppKit
import NearpaneCore
import OSLog
import QuartzCore
@preconcurrency import ScreenCaptureKit

/// A short, input-transparent cover over the pixels that will change. The system
/// continues to own both real windows and routes input to the selected editor.
@MainActor final class WindowSwitchCover: NSPanel {
    static let duration: TimeInterval = 0.16
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    private let picture = CALayer()

    init(frame: CGRect, image: CGImage) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false; isOpaque = false; backgroundColor = .clear; hasShadow = false
        hidesOnDeactivate = false; ignoresMouseEvents = true; sharingType = .none
        animationBehavior = .none; isExcludedFromWindowsMenu = true
        level = .init(rawValue: NSWindow.Level.normal.rawValue + 1)
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenNone]
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        picture.frame = view.bounds; picture.contentsGravity = .resize; picture.contents = image
        view.layer?.addSublayer(picture)
        view.setAccessibilityElement(false)
        contentView = view
        setFrame(frame, display: false)
    }

    static func dissolve(_ picture: CALayer, beginningAt time: CFTimeInterval = 0) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = Float(1); fade.toValue = Float(0); fade.duration = Self.duration
        fade.beginTime = time
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        picture.opacity = 0
        picture.add(fade, forKey: "revealLiveWindow")
        CATransaction.commit()
    }

    func reveal() { Self.dissolve(picture) }

    func discard() {
        orderOut(nil)
        picture.removeAllAnimations()
        picture.contents = nil
        close()
    }
}

@MainActor final class WindowSwitchTransition {
    private static let log = Logger(subsystem: "com.holdsnow.nearpane.alpha", category: "WindowSwitchMotion")
    private final class Shot {
        let scene: WindowSwitchScene
        let prepared = ContinuousClock.now
        let allowed: @MainActor () -> Bool
        weak var gallery: DesktopWindowGallery?
        var operation: UUID?
        var started = false
        var captured: ContinuousClock.Instant?
        var cover: WindowSwitchCover?
        var expiry: Task<Void, Never>?
        init(scene: WindowSwitchScene, gallery: DesktopWindowGallery, allowed: @escaping @MainActor () -> Bool) {
            self.scene = scene; self.gallery = gallery; self.allowed = allowed
        }
    }
    private var active: Shot?
    private var capturing = false

    private func note(_ operation: UUID?, _ phase: StaticString) {
        guard let id = operation else { return }
        Self.log.info("operation=\(id.uuidString, privacy: .public) phase=\(String(describing: phase), privacy: .public) uptime=\(ProcessInfo.processInfo.systemUptime, format: .fixed(precision: 6), privacy: .public)")
    }

    static var permitsAppearance: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && WindowContentPreview.sessionAvailable() &&
            !StageManagerPreference.ownsWindowDispatch && WindowPermissionProbe.screen.allowed()
    }

    func cancel() {
        guard let shot = active else { return }
        active = nil; shot.expiry?.cancel(); shot.expiry = nil
        shot.cover?.discard(); shot.cover = nil
    }

    func cancel(_ id: UUID) {
        if active?.operation == id { cancel() }
    }

    func cancel(on display: String?) {
        if let display, active?.scene.target.display == display { cancel() }
    }

    /// Pointer-down can warm the single window crop. AX presses and group choices
    /// start the same read concurrently with focus admission. A slow read never
    /// delays the focus operation or places the old picture over a landed target.
    func prepare(_ target: DesktopWindowTarget, snapshot: DesktopSnapshot, previews: WindowContentPreview,
                 operation: UUID? = nil, allowed: @escaping @MainActor () -> Bool) {
        if let operation, let shot = active, shot.operation == nil, shot.scene.target == target,
           .now - shot.prepared < .milliseconds(220), shot.allowed(), allowed() {
            shot.operation = operation
            return
        }
        cancel()
        guard allowed(), Self.permitsAppearance, let feed = previews.currentDesktop else { note(operation, "appearanceUnavailable"); return }
        guard let scene = WindowSwitchScene(target: target, snapshot: snapshot) else { note(operation, "noVerifiedChange"); return }
        guard let sourceLife = feed.lifetime(of: scene.source.key), let targetLife = feed.lifetime(of: target.key),
              previews.gallery.allowsSwitchPicture(scene.source), previews.gallery.allowsSwitchPicture(target) else {
            note(operation, "windowLifetimeUnavailable"); return
        }
        let visibility = previews.visibilityGeneration[target.display]
        let shot = Shot(scene: scene, gallery: previews.gallery) { [weak previews, weak feed] in
            guard allowed(), let previews, let feed, previews.visibilityGeneration[target.display] == visibility,
                  previews.visibleDisplays.contains(target.display), feed.lifetime(of: target.key) == targetLife,
                  feed.lifetime(of: scene.source.key) == sourceLife, let live = feed.snapshot,
                  live.native?.stageManagerEnabled == false, target.present(in: live), scene.source.present(in: live),
                  Self.permitsAppearance else { return false }
            return true
        }
        shot.operation = operation
        active = shot
        shot.expiry = Task { [weak self, weak shot] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let shot, self?.active === shot else { return }
            self?.note(shot.operation, "expired"); self?.cancel()
        }
        readPending()
    }

    private func readPending() {
        guard !capturing, let shot = active, !shot.started, shot.allowed(), let gallery = shot.gallery else { return }
        capturing = true; shot.started = true
        Task {
            defer { capturing = false; readPending() }
            let scene = shot.scene, donor = scene.patch.donor == scene.sourceWindow ? scene.source : scene.target
            @MainActor func original() -> Bool {
                active === shot && shot.allowed() && scene.target.sharedSurface(visible: true, matchFrame: true) &&
                    donor.sharedSurface(visible: true, matchFrame: true) &&
                    scene.order() == .original
            }
            guard original() else { return }
            let source: (SCWindow, SCDisplay)
            if let live = gallery.switchCaptureSource(donor, display: scene.displayID) {
                source = live
            } else {
                guard let shareable = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
                      let window = shareable.windows.first(where: { $0.windowID == donor.key.number }),
                      let display = shareable.displays.first(where: { $0.displayID == scene.displayID }),
                      original() else { return }
                source = (window, display)
            }
            guard let image = try? await scene.capture(window: source.0, on: source.1), original() else { return }
            shot.cover = WindowSwitchCover(frame: scene.panelFrame, image: image); shot.captured = .now
            note(shot.operation, "prepared")
        }
    }

    /// Called after the exact-window admission and immediately before dispatch. The
    /// crop is visible before WindowServer reorders either window. Only an actual
    /// change of the front surface may start the dissolve.
    func beforeFocus(_ id: UUID, current: @escaping @MainActor () -> Bool) {
        guard let shot = active, shot.operation == id else { return }
        let scene = shot.scene, donor = scene.patch.donor == scene.sourceWindow ? scene.source : scene.target
        guard let cover = shot.cover, let time = shot.captured, .now - time < .milliseconds(200),
              current(), shot.allowed(), donor.sharedSurface(visible: true, matchFrame: true),
              scene.order() == .original
        else { note(id, "unavailableBeforeWrite"); cancel(); return }
        shot.expiry?.cancel()
        cover.orderFrontRegardless()
        cover.displayIfNeeded()
        CATransaction.flush()
        note(id, "covered")
        shot.expiry = Task { [weak self, weak shot] in
            guard let self, let shot else { return }
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(220))
            var end: ContinuousClock.Instant?
            while !Task.isCancelled, active === shot {
                guard current(), shot.allowed(), donor.sharedSurface(visible: true, matchFrame: true) else { break }
                let order = scene.order()
                if order == .changed || (end != nil && order != .selected) { break }
                if end == nil, order == .selected {
                    cover.reveal()
                    note(id, "revealing")
                    end = .now.advanced(by: .seconds(WindowSwitchCover.duration))
                }
                if let end {
                    if .now >= end { note(id, "completed"); break }
                } else if .now >= deadline { note(id, "presentationTimeout"); break }
                try? await Task.sleep(for: .milliseconds(12))
            }
            if active === shot { cancel() }
        }
    }
}
