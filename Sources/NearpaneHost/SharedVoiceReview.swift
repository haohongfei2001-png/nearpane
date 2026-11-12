#if canImport(SaytileKit) && canImport(RiftletCore)
import AppKit
import NearpaneCore
import NearpaneUI
import SaytileKit

/// Runs the shipped sidebar controller with synthetic input and the real isolated SQLite projection.
@MainActor enum SharedVoiceReview {
    static func run(_ session: NativeAcceptanceSession) async throws {
        guard let screen = NSScreen.screens.first else { throw CocoaError(.featureUnsupported) }
        let root = session.support.appendingPathComponent("Nearpane")
        let modules = EmbeddedModules(support: root, testSession: session.directory, reviewVoice: true)
        guard let fixture = modules.voiceReviewInput else { throw CocoaError(.featureUnsupported) }
        let host = modules.makeHost(store: FileConfigurationStore(url: root.appendingPathComponent("host-configuration.json")))
        await host.start()
        let controller = EdgeWindowController(host: host, modules: modules)
        defer { controller.window?.orderOut(nil); host.stop() }
        controller.place(screens: SystemScreens.geometry())
        guard let window = controller.window else { throw CocoaError(.featureUnsupported) }
        window.ignoresMouseEvents = true
        window.appearance = NSAppearance(named: .aqua)
        let backdrop = NSPanel(contentRect: window.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        defer { backdrop.orderOut(nil) }
        backdrop.isOpaque = true
        backdrop.backgroundColor = NSColor(srgbRed: 0.55, green: 0.61, blue: 0.91, alpha: 1)
        backdrop.title = "Nearpane controlled visual environment"
        backdrop.ignoresMouseEvents = true
        backdrop.hasShadow = false
        backdrop.level = window.level
        backdrop.orderFrontRegardless()
        window.order(.above, relativeTo: backdrop.windowNumber)
        try await fixture.seed()
        for state in ["paused", "standby", "speaking"] {
            if state == "standby" { await fixture.listen() }
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
            let name = "panel-" + state
            let receipt: [String:Any] = ["scene":name, "pid":getpid(), "window":window.windowNumber,
                "backdrop":backdrop.windowNumber,"points":[bounds.width,bounds.height],
                "visible":[visible.minX,visible.minY,visible.width,visible.height],
                "glass":[bounds.minX + surface.x, bounds.maxY - surface.y - surface.height, surface.width, surface.height]]
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
