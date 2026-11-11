import AppKit
import NearpaneCore
import Testing

@testable import NearpaneUI

@MainActor struct WorkspacePanelTests {
    @Test func twoHiddenControllersShareHostAndOnlyPrimaryOwnsDomains() async {
        _ = NSApplication.shared
        let host = HostSession(store: MemoryConfigurationStore())
        await host.start()
        let original = host.registry.states
        let main = EdgeWindowController(host: host)
        var called = [EdgeWindowController]()
        let panels = DisplayPanels(host: host, primary: main, present: { called.append($0) })
        let frame = SurfaceRect(width: 1600, height: 1000)
        let screens = ["a", "b"].map { ScreenGeometry(id: $0, frame: frame, visibleFrame: frame) }
        panels.update(screens: screens)
        #expect(called.count == 1 && panels.secondaryIDs.isEmpty)
        var secondary = DisplaySettings()
        secondary.policy = .pinned
        secondary.measures[.panelWidth] = .init(213.5)
        host.setDisplaySettings(secondary, id: "b")
        called.removeAll()
        panels.update(screens: screens)
        #expect(panels.secondaryIDs == ["b"] && called.count == 2)
        #expect(called.allSatisfy { $0.window?.isVisible == false })
        let second = called.first { $0 !== main }
        #expect(second?.requestedFrame?.width == 213.5)
        #expect(second?.window?.frame == second?.requestedFrame || second?.window?.frame == second?.requestedFrame?.integral)
        #expect(main.window?.frame.width == 200 && main.window?.collectionBehavior.contains(.fullScreenNone) == true)
        panels.dismiss("b")
        panels.update(screens: screens)
        #expect(panels.secondaryIDs.isEmpty && host.registry.states == original)
        panels.request("b")
        panels.update(screens: screens)
        #expect(panels.secondaryIDs == ["b"])
        host.setPlacement(edge: .left, displayID: "b")
        panels.update(screens: screens)
        #expect(panels.secondaryIDs.isEmpty && main.requestedFrame?.width == 213.5)
        #expect(main.window?.frame == main.requestedFrame || main.window?.frame == main.requestedFrame?.integral)
        panels.stop()
        main.close()
        host.stop()
    }

    @Test func secondaryOnlyObservationPreservesRolesWithoutPresentingOnPrimary() async {
        let host = HostSession(store: MemoryConfigurationStore())
        await host.start()
        let main = EdgeWindowController(host: host)
        var presented = [EdgeWindowController]()
        let panels = DisplayPanels(host: host, primary: main, present: { presented.append($0) })
        defer { panels.stop(); main.close(); host.stop() }
        let a = SurfaceRect(width: 1600, height: 1000), b = SurfaceRect(x: -800, width: 800, height: 1280)
        let screens = [ScreenGeometry(id: "a", frame: a, visibleFrame: a), ScreenGeometry(id: "b", frame: b, visibleFrame: b)]
        var settings = DisplaySettings()
        settings.policy = .pinned
        host.setDisplaySettings(settings, id: "b")
        host.setPlacement(edge: .left, displayID: "a")
        panels.update(screens: screens, presentingOnly: "b")
        #expect(!main.hasPlacement && panels.secondaryIDs == ["b"])
        #expect(presented.count == 1 && presented.first !== main && presented.first?.window?.ignoresMouseEvents == true)
        presented.removeAll()
        panels.update(screens: [screens[0]], presentingOnly: "b")
        #expect(!main.hasPlacement && panels.secondaryIDs.isEmpty && presented.isEmpty)
        host.setPlacement(edge: .right, displayID: "b")
        panels.update(screens: screens, presentingOnly: "b")
        #expect(presented.count == 1 && presented.first === main && panels.secondaryIDs.isEmpty)
    }
}
