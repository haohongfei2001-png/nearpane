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
        #expect(host.panelContents["b"] == .spacesOnly && host.panelContents["a"] != nil)
        #expect(presented.count == 1 && presented.first !== main && presented.first?.window?.ignoresMouseEvents == true)
        presented.removeAll()
        panels.update(screens: [screens[0]], presentingOnly: "b")
        #expect(!main.hasPlacement && panels.secondaryIDs.isEmpty && presented.isEmpty)
        #expect(host.panelContents["b"] == nil)
        host.setPlacement(edge: .right, displayID: "b")
        panels.update(screens: screens, presentingOnly: "b")
        #expect(presented.count == 1 && presented.first === main && panels.secondaryIDs.isEmpty)
    }

    @Test func transientExpansionReusesPanelAndNeverCommitsItsFrame() async throws {
        _ = NSApplication.shared
        let store = MemoryConfigurationStore(), frame = SurfaceRect(x: -800, width: 800, height: 1280)
        let screen = ScreenGeometry(id: "portrait", frame: frame, visibleFrame: frame)
        let host = HostSession(store: store)
        await host.start()
        let panel = EdgeWindowController(host: host)
        defer { panel.close(); host.stop() }
        var settings = DisplaySettings()
        settings.measures = [.panelWidth: .init(20), .panelHeight: .init(20), .reservedWidth: .init(104),
                             .textSize: .init(47), .cellWidth: .init(40)]
        host.setDisplaySettings(settings, id: screen.id)
        let persisted = store.value, modules = host.registry.states
        panel.place(on: screen, primary: screen.id, content: .full)
        let initial = try #require(panel.requestedFrame), window = try #require(panel.window)
        let originalHostView = try #require(window.contentView?.subviews.first)
        #expect(initial.size == .init(width: PanelSizeMetrics.minimumSide, height: PanelSizeMetrics.minimumSide))
        for _ in 0..<2 {
            panel.toggleTemporaryExpansion()
            let opened = try #require(panel.requestedFrame)
            #expect(panel.temporarilyExpanded && opened.width > initial.width && opened.height > initial.height)
            #expect(opened.minX >= frame.x && opened.maxX <= frame.x + frame.width)
            #expect(settings.sizeForm(width: opened.width, height: opened.height - PanelSizeMetrics.minimumSide,
                                      content: .full, voice: true, tray: true) == .full)
            #expect(!originalHostView.isHidden && panel.window === window)
            panel.place(on: screen, primary: screen.id, content: .full)
            #expect(panel.temporarilyExpanded && panel.requestedFrame == opened)
            panel.toggleTemporaryExpansion()
            #expect(!panel.temporarilyExpanded && panel.requestedFrame == initial && originalHostView.isHidden)
        }
        #expect(store.value == persisted && host.configuration == persisted && host.registry.states == modules)
        #expect(window.contentView?.subviews.first === originalHostView && !window.isVisible)
        panel.toggleTemporaryExpansion()
        settings.measures[.panelHeight] = .init(714)
        host.setDisplaySettings(settings, id: screen.id)
        panel.place(on: screen, primary: screen.id, content: .full)
        #expect(!panel.temporarilyExpanded && panel.requestedFrame?.size == .init(width: 20, height: 714))
    }

    @Test func expansionCanRecoverUsableRoomFromExtremeSavedInsets() async throws {
        _ = NSApplication.shared
        let area = SurfaceRect(x: -800, width: 800, height: 1280)
        let screen = ScreenGeometry(id: "portrait", frame: area, visibleFrame: area)
        let store = MemoryConfigurationStore(), host = HostSession(store: store)
        await host.start()
        let panel = EdgeWindowController(host: host)
        defer { panel.close(); host.stop() }
        for (side, top) in [(790.0, 34.0), (17.0, 1270.0), (790.0, 1270.0)] {
            var settings = DisplaySettings()
            settings.measures = [.panelWidth: .init(20), .panelHeight: .init(20),
                                 .sideInset: .init(side), .topInset: .init(top), .reservedWidth: .init(96)]
            host.setDisplaySettings(settings, id: screen.id)
            let persisted = store.value
            panel.place(on: screen, primary: screen.id, content: .full)
            let icon = try #require(panel.requestedFrame)
            #expect(icon.size == .init(width: 20, height: 20))
            panel.toggleTemporaryExpansion()
            let expanded = try #require(panel.requestedFrame)
            #expect(settings.sizeForm(width: expanded.width, height: expanded.height - PanelSizeMetrics.minimumSide,
                                      content: .full, voice: true, tray: true) == .full)
            #expect(expanded.minX >= area.x && expanded.maxX <= area.x + area.width)
            #expect(expanded.minY >= area.y && expanded.maxY <= area.y + area.height)
            if top == 34 { #expect(Double(expanded.maxY) == area.y + area.height - top) }
            if side == 17 { #expect(Double(expanded.maxX) == area.x + area.width - side) }
            panel.toggleTemporaryExpansion()
            #expect(panel.requestedFrame == icon && store.value == persisted)
        }
    }

    @Test func tinyPercentageTypeOpensAReadablePanelWithoutReplacingTheSetting() async throws {
        _ = NSApplication.shared
        let area = SurfaceRect(x: -800, width: 800, height: 1280)
        let screen = ScreenGeometry(id: "portrait", frame: area, visibleFrame: area)
        let store = MemoryConfigurationStore(), host = HostSession(store: store)
        await host.start()
        let panel = EdgeWindowController(host: host)
        defer { panel.close(); host.stop() }
        var settings = DisplaySettings()
        settings.measures = [.panelHeight: .init(450), .textSize: .init(0.01, .percent), .labelSize: .init(0.01, .percent)]
        host.setDisplaySettings(settings, id: screen.id)
        panel.place(on: screen, primary: screen.id, content: .full)
        let compact = try #require(panel.requestedFrame)
        panel.toggleTemporaryExpansion()
        let opened = try #require(panel.requestedFrame)
        #expect(panel.temporarilyExpanded && opened.width == 100 && opened.height == 1280)
        let basis = Double(opened.height) - PanelSizeMetrics.minimumSide
        let voice = settings.contentHeights(basis, content: .full, voice: true, tray: true).voice
        #expect(settings.readableFontSize(.textSize, in: voice) == DisplayMetric.textSize.factory.value)
        #expect(settings.readableFontSize(.labelSize, in: basis) == DisplayMetric.labelSize.factory.value)
        panel.toggleTemporaryExpansion()
        #expect(panel.requestedFrame == compact && store.value.displays[screen.id] == settings)
    }
}
