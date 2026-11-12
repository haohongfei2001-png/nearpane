import Foundation
import Testing

@testable import NearpaneCore

struct WorkspaceProjectionTests {
    @Test func windowContentsRequireAnOptInOnEachDisplay() throws {
        let old = try JSONDecoder().decode(DisplaySettings.self, from: Data(#"{"placement":"floating"}"#.utf8))
        #expect(!old.showsWindowContents)
        var work = old
        work.showsWindowContents = true
        let settings = ["work": work, "presentation": DisplaySettings()]
        let restored = try JSONDecoder().decode([String: DisplaySettings].self,
                                                 from: JSONEncoder().encode(settings))
        #expect(restored["work"]?.showsWindowContents == true)
        #expect(restored["presentation"]?.showsWindowContents == false)
    }

    @Test func observationOnlyUsesWitnessedRowsAndActualFramesEvenOutsidePlannedWorkRect() throws {
        let f = NativeDesktopPreviewTests()
        let full = SurfaceRect(x: -800, y: 20, width: 800, height: 1260)
        let w = f.window(88, full, 0, .known(recordIDs: ["9"]))
        let s = f.sample([w], rows: [f.proof])
        let projected = try #require(
            NativeSpacesProvider().projection(
                s, preferredDisplay: "wide", settings: [:], edge: .right, date: f.date, uptime: 42))
        let id = try #require(s.workspaceID(display: "portrait", record: "9"))
        #expect(projected.rows.count == 1 && projected.rows[id]?.area.width == 700)
        #expect(projected.rows[id]?.layout == nil && projected.grants.isEmpty)
        let viewport = SurfaceRect(x: 10, y: 5, width: 80, height: 126)
        let wholeRow = SurfaceRect(width: 140, height: 140)
        let preview = try #require(
            DesktopPreview(
                snapshot: s, displayID: "portrait", viewport: viewport, now: f.date, uptime: 42, restrictToDisplay: true,
                rowViewport: wholeRow))
        #expect(preview.rows[0].windows.first?.frame == viewport && preview.rows[0].rowFrame == wholeRow)
        let other = try #require(
            DesktopPreview(
                snapshot: s, displayID: "wide", viewport: viewport, now: f.date, uptime: 42, restrictToDisplay: true))
        #expect(other.rows.map(\.kind) == [.visibleDisplay])
        #expect(
            NativeSpacesProvider().projection(
                s, preferredDisplay: "wide", settings: [:], edge: .right, date: f.date, uptime: 80) == nil)
        var transient = s
        transient.freshness = .transient
        #expect(
            DesktopPreview(snapshot: transient, displayID: "portrait", viewport: viewport, now: f.date, uptime: 42) == nil)
    }
    @MainActor @Test func perDisplayPrecisionResetAndPoliciesSurviveHostRestartWithoutDomainRecreation() async throws {
        let store = MemoryConfigurationStore()
        let host = HostSession(store: store)
        await host.start()
        let domainStates = host.registry.states
        var a = DisplaySettings()
        var b = DisplaySettings()
        a.measures[.panelWidth] = .init(18.75, .percent)
        a.measures[.textSize] = .init(14.5)
        b.placement = .floating
        b.policy = .pinned
        b.measures[.trayPadding] = .init(6.5)
        host.setDisplaySettings(a, id: "a")
        host.setDisplaySettings(b, id: "b")
        a.measures[.textSize] = nil
        host.setDisplaySettings(a, id: "a")
        var prefs = WorkspacePreferences()
        prefs.overflow = .continuousSplit
        host.setWorkspacePreferences(prefs)
        #expect(host.registry.states == domainStates && host.workspaceMode.mode == .native)
        host.stop()
        await host.start()
        #expect(
            host.configuration.displays["a"] == a && host.configuration.displays["b"] == b
                && host.configuration.workspaces == prefs)
        let safe = SurfaceRect(width: 1600, height: 900)
        let screen = ScreenGeometry(id: "a", frame: safe, visibleFrame: safe)
        #expect(a.panel(on: screen, fallbackEdge: .right)?.width == 300)
        #expect(a.referenceExtent(for: .panelWidth, screen: screen, primary: true) == 1600)
        #expect(try JSONDecoder().decode(DisplaySettings.self, from: Data("{}".utf8)).placement == .docked)
        var invalid = a
        invalid.measures[.textSize] = .init(.nan)
        host.setDisplaySettings(invalid, id: "a")
        #expect(host.configurationSaveFailed && store.value.displays["a"] == a)
        host.stop()
    }
}
