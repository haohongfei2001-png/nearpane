import AppKit
import SwiftUI
import NearpaneCore
import Testing

@testable import NearpaneUI

@MainActor struct WorkspacePanelTests {
    @Test func compactLiveVoiceAndTrayKeepTheirControlsWhenTheSwitcherYields() throws {
        let rect = SurfaceRect(width: 1470, height: 923)
        let screen = ScreenGeometry(id: "primary", frame: rect, visibleFrame: rect)
        let layout = try #require(PanelSizeLayout(settings: .init(), screen: screen, edge: .right,
            content: .toolsOnly, voice: true, tray: true, floating: false, voiceCompact: true))
        #expect(layout.form == .full)
        #expect(layout.frame.height < rect.height / 3)
        let twoRows = try #require(PanelSizeLayout(settings: .init(), screen: screen, edge: .right,
            content: .toolsOnly, voice: true, tray: true, floating: false, voiceCompact: true, trayRows: 2))
        #expect(twoRows.form == .full && twoRows.frame.height > layout.frame.height)
    }

    @Test func stageManagerOwnsTheSwitcherAndReleasesItWithoutChangingSettings() async throws {
        let host = HostSession(store: MemoryConfigurationStore())
        await host.start()
        let panel = EdgeWindowController(host: host)
        let panels = DisplayPanels(host: host, primary: panel, present: { _ in })
        defer { panels.stop(); panel.close(); host.stop() }
        let rect = SurfaceRect(width: 1440, height: 900)
        let screen = ScreenGeometry(id: "primary", frame: rect, visibleFrame: rect)
        var preferences = DisplaySettings()
        preferences.measures[.panelHeight] = .init(850)
        host.setDisplaySettings(preferences, id: screen.id)
        let committedPreferences = try #require(host.configuration.displays[screen.id])
        panels.update(screens: [screen])
        let originalContent = host.panelContents[screen.id]
        let originalHeight = try #require(panel.requestedFrame?.height)
        panels.setSystemManagesWindows(true)
        panels.request(screen.id)
        panels.update(screens: [screen])
        #expect(host.panelContents[screen.id] == .toolsOnly)
        #expect(try #require(panel.requestedFrame?.height) < originalHeight)
        #expect(panel.window?.collectionBehavior.contains(.transient) == true)
        #expect(panel.window?.collectionBehavior.contains(.stationary) == false)
        panels.setMissionControl(.exposed)
        panels.update(screens: [screen])
        #expect(host.panelContents[screen.id] == .hidden)
        panels.setMissionControl(.ordinary)
        panels.update(screens: [screen])
        #expect(host.panelContents[screen.id] == .toolsOnly)
        panels.setSystemManagesWindows(false)
        #expect(!panels.windowDispatchEligible)
        panels.setMissionControl(.ordinary)
        panels.update(screens: [screen])
        #expect(host.panelContents[screen.id] == originalContent)
        #expect(panel.requestedFrame?.height == originalHeight)
        #expect(host.configuration.displays[screen.id] == committedPreferences)
        #expect(committedPreferences.retiredVisualOverrides[.panelHeight] == Measure(850))
    }

    @Test func residentCanRequestTheOnlyDesktopWithAllInputModulesOff() async throws {
        let host = HostSession(store: MemoryConfigurationStore())
        await host.start()
        let controller = EdgeWindowController(host: host)
        let panels = DisplayPanels(host: host, primary: controller, present: { _ in })
        defer { panels.stop(); controller.close(); host.stop() }
        // Notes is now part of the first-run preset. This scenario intentionally
        // exercises a Spaces-only resident with every writing/capture tool off.
        for module in [BuiltinCatalog.voice, BuiltinCatalog.screenshots, BuiltinCatalog.memo] {
            #expect(host.handle(.setEnabled(module, false)) == .accepted)
        }
        let frame = SurfaceRect(width: 1440, height: 900)
        let screen = ScreenGeometry(id: "one", frame: frame, visibleFrame: frame)
        let row = ObservedSpaceRow(displayID: screen.id, scopeID: "screen", recordID: "A",
            anchor: .init(number: 17, displayID: screen.id, globalFrame: .init(width: 180, height: 90)))
        let now = Date(), uptime = ProcessInfo.processInfo.systemUptime
        let snapshot = DesktopSnapshot.observed(
            .init(session: UUID(), revision: 1, parentPID: 1, fixtureWindows: nil, anchors: [row.anchor], experimentalSpaces: true),
            from: now, to: now, build: "fixture", topology: "single", consistent: true, separateSpaces: false,
            displays: [.init(id: screen.id, frame: frame, rotationDegrees: 0, backingScale: 1, usable: frame)],
            scopes: [.init(id: row.scopeID, displayID: screen.id, records: [.init(id: row.recordID, isCurrent: true)])],
            windows: [], evidence: .init(population: .workWindows, accessibility: .available, spaces: .observed,
                rows: [row], windowLimitReached: false, beganUptime: uptime, endedUptime: uptime))
        host.bus.resetDesktopSession()
        #expect(host.bus.acceptDesktop(snapshot))
        func workArea() throws -> DesktopWorkArea {
            try .init(display: screen.id, screen: frame, usable: frame, primary: true,
                      settings: host.configuration.displays[screen.id] ?? .init(), fallbackEdge: host.configuration.edge)
        }
        let original = try workArea()
        panels.update(screens: [screen])
        #expect(host.panelContents[screen.id] == .hidden && !controller.hasPlacement)
        panels.request(screen.id)
        panels.update(screens: [screen])
        panels.update(screens: [screen])
        #expect(host.panelContents[screen.id] == .spacesOnly && controller.hasPlacement)
        #expect(try workArea() == original)
        panels.dismiss(screen.id)
        panels.update(screens: [screen])
        #expect(host.panelContents[screen.id] == .hidden && !controller.hasPlacement)
        #expect(host.configuration.displays[screen.id]?.spacesDismissed == true)
        panels.request(screen.id)
        panels.update(screens: [screen])
        #expect(host.panelContents[screen.id] == .spacesOnly && controller.hasPlacement)
        #expect(try workArea() == original)

        // Legacy icon dimensions now migrate to the supported, directly usable surface.
        // Real constrained-area expansion is covered by transientExpansion below.
        var legacy = host.configuration.displays[screen.id] ?? .init()
        legacy.measures[.panelWidth] = .init(PanelSizeMetrics.minimumSide)
        legacy.measures[.panelHeight] = .init(PanelSizeMetrics.minimumSide)
        host.setDisplaySettings(legacy, id: screen.id)
        let committed = try #require(host.configuration.displays[screen.id])
        panels.update(screens: [screen])
        let ready = try #require(controller.requestedFrame)
        let migratedArea = try workArea()
        #expect(!controller.temporarilyExpanded && ready.width == 220)
        #expect(committed.retiredVisualOverrides[.panelHeight] == Measure(PanelSizeMetrics.minimumSide))
        panels.request(screen.id)
        panels.update(screens: [screen])
        #expect(!controller.temporarilyExpanded && controller.requestedFrame == ready)
        panels.request(screen.id)
        panels.update(screens: [screen])
        #expect(!controller.temporarilyExpanded)
        controller.toggleTemporaryExpansion()
        panels.update(screens: [screen])
        #expect(!controller.temporarilyExpanded && controller.requestedFrame == ready)
        #expect(host.configuration.displays[screen.id] == committed)
        #expect(try workArea() == migratedArea)
    }

    @Test func unidentifiedMenuDisplayCannotPromoteAPortraitScreenIntoTheQuartzOrigin() {
        let f = SurfaceRect(width: 1600, height: 900)
        let g = SurfaceRect(x: -800, y: -320, width: 800, height: 1280)
        let primary = ScreenGeometry(id: "menu", frame: f, visibleFrame: f)
        let side = ScreenGeometry(id: "side", frame: g, visibleFrame: g)
        let invalid = ScreenGeometry(id: "menu", frame: f, visibleFrame: g)
        #expect(SystemScreens.identifiedTopology([nil, side]).isEmpty)
        #expect(SystemScreens.identifiedTopology([invalid, side]).isEmpty)
        #expect(SystemScreens.identifiedTopology([primary, side, primary]).isEmpty)
        #expect(SystemScreens.identifiedTopology([primary, nil, side]) == [primary, side])
    }

    @Test func ambiguousDisplayCannotContributeAPresentationWitnessOrBecomeResident() async {
        let host = HostSession(store: MemoryConfigurationStore())
        await host.start()
        let main = EdgeWindowController(host: host)
        let panels = DisplayPanels(host: host, primary: main, present: { _ in })
        defer { panels.stop(); main.close(); host.stop() }
        let r = SurfaceRect(width: 1000, height: 800)
        let good = ScreenGeometry(id: "primary", frame: r, visibleFrame: r)
        let bad = ScreenGeometry(id: "duplicate", frame: r, visibleFrame: .init(width: 0, height: 0))
        let other = ScreenGeometry(id: "duplicate", frame: r, visibleFrame: r)
        host.setPlacement(edge: .right, displayID: "duplicate")
        var observed = [String]()
        panels.fixtureFullscreen = { id in observed.append(id); return nil }
        let unknown = ScreenGeometry(id: "unidentified-display", frame: r, visibleFrame: r)
        panels.update(screens: [bad, other, unknown, good])
        #expect(observed == ["primary"])
        #expect(host.panelContents.keys.sorted() == ["primary"] && main.hasPlacement)
        #expect(host.configuration.preferredDisplayID == "duplicate")
    }

    @Test func disconnectReclaimsFloatingCallbacksAndReusesTheResidentController() async throws {
        let host = HostSession(store: MemoryConfigurationStore())
        await host.start()
        let main = EdgeWindowController(host: host)
        var presented = [EdgeWindowController]()
        let panels = DisplayPanels(host: host, primary: main, present: { presented.append($0) })
        defer { panels.stop(); main.close(); host.stop() }
        let f = SurfaceRect(width: 1600, height: 900)
        let g = SurfaceRect(x: -800, width: 800, height: 1280)
        let a = ScreenGeometry(id: "a", frame: f, visibleFrame: f)
        let b = ScreenGeometry(id: "b", frame: g, visibleFrame: g)
        var settings = DisplaySettings()
        settings.policy = .pinned
        settings.placement = .floating
        settings.measures[.panelWidth] = .init(250)
        host.setDisplaySettings(settings, id: b.id)
        host.setPlacement(edge: .right, displayID: a.id)
        let saved = host.configuration, states = host.registry.states
        panels.update(screens: [a,b])
        let old = try #require(presented.first { $0 !== main })
        let staleMove = try #require((old.window as? EdgePanel)?.floatMoved)
        let primaryWindow = main.window
        panels.update(screens: [b])
        staleMove(.init(x: 5, y: 6))
        #expect(host.configuration == saved && !old.hasPlacement && main.requestedFrame?.width == 250)
        presented.removeAll()
        panels.update(screens: [b,a])
        #expect(presented.first === main && panels.secondaryIDs == ["b"])
        #expect(main.window === primaryWindow && main.requestedFrame?.width == 256)
        #expect(host.configuration == saved && host.registry.states == states)
        host.setSurfaceHidden(true)
        presented.removeAll()
        for _ in 0..<10 { panels.update(screens: [b,a]) }
        #expect(presented.isEmpty && !main.hasPlacement && panels.secondaryIDs.isEmpty)
        #expect(!old.window!.isVisible && main.window === primaryWindow)
    }

    @Test func onlyFreshLiveDisplaySamplesCanRenewAManagementReturnWitness() {
        let view = FullscreenPresentation(host: HostSession(store: MemoryConfigurationStore()), domains: nil)
        let frame = SurfaceRect(width: 900, height: 700)
        let screen = ScreenGeometry(id: "secondary", frame: frame, visibleFrame: frame)
        let session = UUID()
        var events = [String](), deadlines = [Double?]()
        view.updateTopology([screen], uptime: 100)
        view.management = { _, state, deadline in events.append(state); deadlines.append(deadline) }
        func feed(_ revision: UInt64, end: Double, suspended: Bool = false) {
            let reading = FullscreenDisplaySample(session: session, revision: revision, validUntil: end,
                                                   observation: .ordinary(workspace: nil))
            _ = view.sample(screen: screen, override: reading, now: Date(), uptime: 105, suspended: suspended)
        }
        feed(1, end: 110)
        feed(1, end: 111) // an ordinary redraw must not extend the lease
        feed(2, end: 115)
        feed(3, end: 116, suspended: true)
        feed(4, end: 117)
        view.updateTopology([], uptime: 106)
        #expect(events == ["ordinary", "ordinary", "unknown", "ordinary", "unknown"])
        #expect(deadlines == [110, 115, nil, 117, nil])
    }

    @Test func samePointFramesWithChangedRotationOrScaleRetireDragAndFullscreenWitnesses() async throws {
        let host = HostSession(store: MemoryConfigurationStore())
        await host.start()
        let panel = EdgeWindowController(host: host)
        defer { panel.close(); host.stop() }
        let view = FullscreenPresentation(host: host, domains: nil)
        var events = [String]()
        view.management = { _, state, _ in events.append(state) }
        let session = UUID()
        let window = ManagedWindowID(pid: 8, launch: 10, number: 15, element: UUID())
        let area = SurfaceRect(x: -800, width: 800, height: 1280)
        let screens = [(0.0, 1.0), (180.0, 1.0), (180.0, 2.0)].map {
            ScreenGeometry(id: "side", frame: area, visibleFrame: area, rotationDegrees: $0.0, backingScale: $0.1)
        }
        var settings = DisplaySettings()
        settings.placement = .floating
        settings.measures[.panelWidth] = .init(260.5)
        host.setDisplaySettings(settings, id: "side")
        let saved = host.configuration
        let edge = try #require(panel.window)
        #expect(edge.animationBehavior == .none)
        var previousMove: ((NSPoint) -> Void)?
        for (index, screen) in screens.enumerated() {
            let t = Double(200 + index)
            view.updateTopology([screen], uptime: t)
            panel.place(on: screen, primary: "resident", content: .spacesOnly)
            if let previousMove {
                previousMove(.init(x: 3, y: 5))
                #expect(events.last == "unknown")
            }
            #expect(host.configuration == saved && panel.requestedFrame?.size == NSSize(width: 260.5, height: 1280))
            let reading = FullscreenDisplaySample(session: session, revision: UInt64(index + 1), validUntil: t + 12,
                                                  observation: .native(window: window), beganUptime: t)
            _ = view.sample(screen: screen, override: reading, now: Date(), uptime: t, suspended: false)
            #expect(events.last == "hold")
            previousMove = try #require((panel.window as? EdgePanel)?.floatMoved)
        }
        previousMove?(.init(x: 3, y: 5))
        #expect(host.configuration.displays["side"]?.floatingPosition?.x == 3)
    }

    @Test func systemWakeDoesNotReleaseTheDisplayOrLoginLockOnItsOwn() {
        var state = DesktopSessionAvailability()
        func observe(_ event: DesktopSessionAvailability.Event, console: Bool = true, locked: Bool = false, awake: Bool = true) {
            state.observe(event, hasAwakeDisplay: awake, consoleActive: console, consoleLocked: locked)
        }
        observe(.sample)
        #expect(!state.unavailable)
        observe(.willSleep)
        observe(.screensSleep)
        observe(.screensWake)
        #expect(state.desktopAsleep)
        observe(.locked)
        observe(.didWake)
        #expect(!state.desktopAsleep && state.unavailable)
        observe(.unlocked, locked: true)
        #expect(state.unavailable)
        observe(.sample, console: false)
        #expect(state.unavailable)
        observe(.resigned)
        observe(.sample)
        #expect(state.unavailable)
        observe(.becameActive, awake: false)
        #expect(state.desktopAsleep && !state.sessionRestricted)
        observe(.sample)
        #expect(!state.unavailable)
    }

    @Test func wakingRejectsUnexpiredFullscreenAndReturnReadsFromBeforeResume() {
        let view = FullscreenPresentation(host: HostSession(store: MemoryConfigurationStore()), domains: nil)
        let frame = SurfaceRect(width: 1200, height: 900)
        let screen = ScreenGeometry(id: "fixture", frame: frame, visibleFrame: frame)
        let session = UUID(), window = ManagedWindowID(pid: 4, launch: 8, number: 12, element: UUID())
        var notices: [String] = []
        view.management = { _, message, _ in notices.append(message) }
        func feed(_ revision: UInt64, _ began: Double?, _ observation: DesktopFullscreenObservation, _ now: Double) -> Bool {
            let sample = FullscreenDisplaySample(session: session, revision: revision, validUntil: now + 5,
                                                  observation: observation, beganUptime: began)
            return view.sample(screen: screen, override: sample, now: Date(), uptime: now)
        }
        view.updateTopology([screen], uptime: 10)
        #expect(feed(1, 10, .native(window: window), 10.5))
        view.sessionBoundary(uptime: 11)
        view.sessionBoundary(uptime: 12)
        #expect(feed(2, 11.9, .ordinary(workspace: nil), 13))
        #expect(feed(3, nil, .ordinary(workspace: nil), 13))
        #expect(notices == ["hold", "unknown"])
        #expect(!feed(4, 12.5, .ordinary(workspace: nil), 13))
        #expect(notices == ["hold", "unknown", "ordinary"])
    }

    @Test func reconnectAndRotationRequireAnObservationStartedOnTheNewTopology() {
        let view = FullscreenPresentation(host: HostSession(store: MemoryConfigurationStore()), domains: nil)
        let portrait = SurfaceRect(x: -800, width: 800, height: 1280)
        let wide = SurfaceRect(x: -1280, width: 1280, height: 800)
        let a = ScreenGeometry(id: "stable-display", frame: portrait, visibleFrame: portrait)
        let b = ScreenGeometry(id: a.id, frame: wide, visibleFrame: wide)
        let session = UUID(), window = ManagedWindowID(pid: 11, launch: 22, number: 33, element: UUID())
        var events = [String]()
        view.management = { _, state, _ in events.append(state) }
        func feed(_ screen: ScreenGeometry, _ revision: UInt64, began: Double, ordinary: Bool = false) {
            let sample = FullscreenDisplaySample(session: session, revision: revision, validUntil: began + 12,
                observation: ordinary ? .ordinary(workspace: nil) : .native(window: window), beganUptime: began)
            _ = view.sample(screen: screen, override: sample, now: Date(), uptime: 105)
        }
        view.updateTopology([a], uptime: 100)
        feed(a, 1, began: 100)
        view.updateTopology([b], uptime: 102)
        feed(b, 2, began: 101, ordinary: true)
        #expect(events == ["hold", "unknown"])
        feed(b, 3, began: 103, ordinary: true)
        view.updateTopology([], uptime: 103)
        view.updateTopology([b], uptime: 104)
        feed(b, 4, began: 103)
        #expect(events.last == "unknown")
        feed(b, 5, began: 105)
        #expect(events.last == "hold")
    }

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
        secondary.measures[.panelWidth] = .init(273.5)
        host.setDisplaySettings(secondary, id: "b")
        called.removeAll()
        panels.update(screens: screens)
        #expect(panels.secondaryIDs == ["b"] && called.count == 2)
        #expect(called.allSatisfy { $0.window?.isVisible == false })
        let second = called.first { $0 !== main }
        #expect(second?.requestedFrame?.width == 273.5)
        #expect(second?.window?.frame == second?.requestedFrame || second?.window?.frame == second?.requestedFrame?.integral)
        #expect(main.window?.frame.width == 256 && main.window?.collectionBehavior.contains(.fullScreenNone) == true)
        panels.dismiss("b")
        panels.update(screens: screens)
        #expect(panels.secondaryIDs.isEmpty && host.registry.states == original)
        panels.request("b")
        panels.update(screens: screens)
        #expect(panels.secondaryIDs == ["b"])
        host.setPlacement(edge: .left, displayID: "b")
        panels.update(screens: screens)
        #expect(panels.secondaryIDs.isEmpty && main.requestedFrame?.width == 273.5)
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
        // A genuine constrained usable area, not a retired per-element override,
        // puts the normal panel below its comfortable 176 pt presentation width.
        let usable = SurfaceRect(x: -168, y: 40, width: 168, height: 620)
        let screen = ScreenGeometry(id: "portrait", frame: frame, visibleFrame: usable)
        let host = HostSession(store: store)
        await host.start()
        let panel = EdgeWindowController(host: host)
        defer { panel.close(); host.stop() }
        var settings = DisplaySettings()
        settings.measures = [.panelWidth: .init(260), .textSize: .init(16)]
        host.setDisplaySettings(settings, id: screen.id)
        let persisted = store.value, modules = host.registry.states
        let presentation = host.panelPresentationSettings(on: screen.id)
        panel.place(on: screen, primary: screen.id, content: .full)
        let initial = try #require(panel.requestedFrame), window = try #require(panel.window)
        let originalHostView = try #require(window.contentView?.subviews.first { $0 is NSHostingView<EdgeSurfaceView> })
        #expect(initial.size == .init(width: usable.width, height: usable.height))
        #expect(originalHostView.isHidden && !panel.temporarilyExpanded)
        for _ in 0..<2 {
            panel.toggleTemporaryExpansion()
            let opened = try #require(panel.requestedFrame)
            #expect(panel.temporarilyExpanded)
            #expect(opened.minX >= usable.x && opened.maxX <= usable.x + usable.width)
            #expect(opened.minY >= usable.y && opened.maxY <= usable.y + usable.height)
            #expect(presentation.sizeForm(width: opened.width, height: opened.height - PanelSizeMetrics.minimumSide,
                                          content: .full, voice: true, tray: true, temporarilyExpanded: true) == .full)
            #expect(!originalHostView.isHidden && panel.window === window)
            window.contentView?.layoutSubtreeIfNeeded()
            let close = try #require(window.contentView?.subviews.compactMap { $0 as? NSButton }
                .first { $0.accessibilityIdentifier() == "nearpane-close-panel" })
            #expect(!close.isHidden && close.frame.width >= PanelSizeMetrics.minimumSide && close.frame.height >= PanelSizeMetrics.minimumSide)
            panel.place(on: screen, primary: screen.id, content: .full)
            #expect(panel.temporarilyExpanded && panel.requestedFrame == opened)
            close.performClick(nil)
            #expect(!panel.temporarilyExpanded && panel.requestedFrame == initial && originalHostView.isHidden)
        }
        #expect(store.value == persisted && host.configuration == persisted && host.registry.states == modules)
        #expect(originalHostView.superview === window.contentView && !window.isVisible)
        panel.toggleTemporaryExpansion()
        let restored = ScreenGeometry(id: screen.id, frame: frame, visibleFrame: frame)
        panel.place(on: restored, primary: screen.id, content: .full)
        #expect(!panel.temporarilyExpanded && panel.requestedFrame?.size == .init(width: 260, height: 1280))
        #expect(!originalHostView.isHidden && store.value == persisted)
    }

    @Test func retiredExtremeInsetsCannotObstructTheAvailablePanel() async throws {
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
            let committed = try #require(host.configuration.displays[screen.id])
            panel.place(on: screen, primary: screen.id, content: .full)
            let ready = try #require(panel.requestedFrame)
            #expect(ready.size == .init(width: 220, height: 1280))
            #expect(committed.sizeForm(width: ready.width, height: ready.height,
                                      content: .full, voice: true, tray: true) == .full)
            #expect(ready.minX >= area.x && ready.maxX <= area.x + area.width)
            #expect(ready.minY >= area.y && ready.maxY <= area.y + area.height)
            #expect(committed.measures[.sideInset] == nil && committed.measures[.topInset] == nil)
            #expect(committed.retiredVisualOverrides[.sideInset] == Measure(side))
            #expect(committed.retiredVisualOverrides[.topInset] == Measure(top))
            let content = try #require(panel.window?.contentView?.subviews.first { $0 is NSHostingView<EdgeSurfaceView> })
            #expect(!content.isHidden)
            panel.toggleTemporaryExpansion()
            #expect(!panel.temporarilyExpanded && panel.requestedFrame == ready && store.value == persisted)
        }
    }

    @Test func retiredPercentageTypeBecomesReadableWithoutLosingItsOriginalValue() async throws {
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
        let committed = try #require(host.configuration.displays[screen.id])
        panel.place(on: screen, primary: screen.id, content: .full)
        let ready = try #require(panel.requestedFrame)
        #expect(!panel.temporarilyExpanded && ready.width == 220 && ready.height == 1280)
        #expect(committed.measures[.textSize] == Measure(12) && committed.measures[.labelSize] == Measure(10))
        #expect(committed.retiredVisualOverrides[.textSize] == settings.measures[.textSize])
        #expect(committed.retiredVisualOverrides[.labelSize] == settings.measures[.labelSize])
        #expect(committed.sizeForm(width: ready.width, height: ready.height, content: .full, voice: true, tray: true) == .full)
        panel.toggleTemporaryExpansion()
        #expect(!panel.temporarilyExpanded && panel.requestedFrame == ready && store.value.displays[screen.id] == committed)
    }
}
