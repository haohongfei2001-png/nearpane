#if canImport(SaytileKit) && canImport(RiftletCore)
import AppKit
import NearpaneCore
import NearpaneUI
import SaytileKit
import SaytileVoiceUI

/// Runs the shipped sidebar controller with synthetic input and the real isolated SQLite projection.
@MainActor enum SharedVoiceReview {
    static func run(_ session: NativeAcceptanceSession) async throws {
        guard let screen = NSScreen.screens.first else { throw CocoaError(.featureUnsupported) }
        let root = session.support.appendingPathComponent("Nearpane")
        let modules = EmbeddedModules(support: root, testSession: session.directory, reviewVoice: true)
        guard let fixture = modules.voiceReviewInput else { throw CocoaError(.featureUnsupported) }
        let desktop = SharedVoiceReviewScene(screen: screen)
        defer { desktop.close() }
        try await desktop.importTray(into: session.support.appendingPathComponent("Riftlet", isDirectory: true))
        let store = FileConfigurationStore(url: root.appendingPathComponent("host-configuration.json"))
        let provider = NativeDesktopProvider.packaged(fixtureWindows: { desktop.windows })
        let host = modules.makeHost(store: store, provider: provider)
        let screens = SystemScreens.geometry()
        guard let displayID = screens.first?.id else { throw CocoaError(.featureUnsupported) }
        await host.start()
        var settings = host.configuration.displays[displayID] ?? .init()
        settings.showsWindowContents = true
        let referenceWidth = ProcessInfo.processInfo.environment["NEARPANE_REVIEW_ARTWORK_WIDTH"] == "1"
        if referenceWidth { settings.measures[.panelWidth] = Measure(100 * 325 / 1672, .percent) }
        host.setDisplaySettings(settings, id: displayID)
        await modules.tray.connect()
        guard modules.tray.visibleIDs.count == 3 else { throw CocoaError(.validationMissingMandatoryProperty) }
        let controller = EdgeWindowController(host: host, modules: modules)
        defer { controller.window?.orderOut(nil); host.stop() }
        controller.place(screens: screens)
        controller.presentIfNeeded()
        guard let window = controller.window else { throw CocoaError(.featureUnsupported) }
        window.ignoresMouseEvents = true
        window.appearance = NSAppearance(named: .aqua)
        let backdrop = NSPanel(contentRect: window.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        defer { backdrop.orderOut(nil) }
        backdrop.isOpaque = true
        backdrop.backgroundColor = NSColor(srgbRed: 0.55, green: 0.61, blue: 0.91, alpha: 1)
        if let environment = NSImage(contentsOf: session.directory.appendingPathComponent("environment.png")) {
            let view = NSImageView()
            view.image = environment; view.imageScaling = .scaleAxesIndependently
            backdrop.contentView = view
        }
        backdrop.title = "Nearpane controlled visual environment"
        backdrop.ignoresMouseEvents = true
        backdrop.hasShadow = false
        backdrop.level = window.level
        backdrop.orderFrontRegardless()
        window.order(.above, relativeTo: backdrop.windowNumber)
        try await fixture.seed()
        let ready = ContinuousClock.now + .seconds(6)
        while host.bus.desktop?.windows.count != desktop.windows.count, ContinuousClock.now < ready {
            try await Task.sleep(for: .milliseconds(100))
        }
        let states = referenceWidth ? ["speaking"] : ["paused", "standby", "speaking"]
        for state in states {
            if state == "standby" || referenceWidth { await fixture.listen() }
            if state == "speaking" { fixture.speak() }
            try await Task.sleep(for: .milliseconds(550))
            window.contentView?.layoutSubtreeIfNeeded()
            let expected: CaptureState = state == "paused" ? .paused : state == "standby" ? .listening : .speaking
            guard modules.voice.capture == expected, !window.isKeyWindow, window.isVisible, !NSApp.isActive,
                  !modules.voice.transcript.isEmpty else {
                let checks = "capture=\(modules.voice.capture == expected) key=\(window.isKeyWindow) visible=\(window.isVisible) active=\(NSApp.isActive) hasText=\(!modules.voice.transcript.isEmpty)"
                throw NSError(domain: "SharedVoiceReview", code: 1, userInfo: [NSLocalizedDescriptionKey: checks])
            }
            let bounds = window.frame
            let layout = LayoutComposer.compose(width: bounds.width, height: bounds.height,
                pinnedCount: host.registry.pinnedModules.count, expanded: false, settings: .init())
            let surface = layout.voice, visible = screen.visibleFrame
            let slot = CGRect(x: bounds.minX + surface.x, y: bounds.maxY - surface.y - surface.height,
                              width: surface.width, height: surface.height)
            let inner = VoiceRailMetrics(width: bounds.width).cardFrame(in: slot)
            guard let sample = host.bus.desktop, sample.native?.population == .markedFixture,
                  Set(sample.windows.compactMap { $0.metadata?.number }) == Set(desktop.windows.map { UInt32($0.windowNumber) }),
                  sample.windows.allSatisfy({ $0.metadata?.pid == getpid() }) else {
                throw NSError(domain: "SharedVoiceReview", code: 2, userInfo: [NSLocalizedDescriptionKey:
                    "Expected four owned windows, observed \(host.bus.desktop?.windows.count ?? 0), reader=\(provider.capabilities.observation)"])
            }
            let name = "panel-" + state
            let receipt: [String:Any] = ["scene":name, "pid":getpid(), "window":window.windowNumber,
                "backdrop":backdrop.windowNumber,"points":[bounds.width,bounds.height],
                "visible":[visible.minX,visible.minY,visible.width,visible.height],
                "glass":[inner.minX, inner.minY, inner.width, inner.height],
                "trayAssets":modules.tray.visibleIDs.count, "desktopWindows":sample.windows.count,
                "desktopPopulation":"markedFixture","referenceWidth":referenceWidth, "witnessedSpaces":sample.native?.rows.count ?? 0]
            let json = try JSONSerialization.data(withJSONObject: receipt, options: .sortedKeys)
            try json.write(to: session.directory.appendingPathComponent("request.json"), options: .atomic)
            let done = session.directory.appendingPathComponent(name + ".done")
            for _ in 0..<200 where !FileManager.default.fileExists(atPath: done.path) {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard try String(contentsOf: done, encoding: .utf8) == "captured" else { throw CocoaError(.fileReadCorruptFile) }
        }
        fixture.finishPhrase()
        guard modules.voice.capture == .listening else { throw CocoaError(.validationMissingMandatoryProperty) }
        host.stop()
        await modules.finishStopping()
    }
}
#endif
