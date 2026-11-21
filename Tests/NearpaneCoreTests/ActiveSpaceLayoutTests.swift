import Foundation
import Testing
@testable import NearpaneCore

struct ActiveSpaceLayoutTests {
    let date = Date(timeIntervalSince1970: 500)
    let fullUUID = UUID()
    let ordinaryUUID = UUID()
    let otherUUID = UUID()
    let userDisplay = DisplayObservation(id: "12000000-0000-0000-0000-000000000001", frame: .init(x: -1200, y: 120, width: 1200, height: 800),
        rotationDegrees: 0, backingScale: 2, usable: .init(x: 0, y: 20, width: 1200, height: 780))
    let otherDisplay = DisplayObservation(id: "12000000-0000-0000-0000-000000000002", frame: .init(width: 1000, height: 800),
        rotationDegrees: 0, backingScale: 1, usable: .init(width: 1000, height: 800))
    let left = SurfaceRect(width: 440, height: 800)
    let right = SurfaceRect(x: 452, y: 0, width: 748, height: 800)
    func window(_ n: UInt32, _ local: SurfaceRect, on supplied: DisplayObservation? = nil,
                space: String? = "7", ordinary: String? = nil, membership: WindowMembership? = nil,
                full: Bool? = true, tile: Bool? = true, geometry: Bool = true, role: Bool? = true,
                shown: Bool = true, onscreen: Bool = true, active: Bool = true, minimized: Bool? = false) -> WindowObservation {
        let display = supplied ?? userDisplay
        let cg = SurfaceRect(x: display.frame.x + local.x, y: display.frame.y + local.y,
                             width: local.width, height: local.height)
        let ids = [space ?? ordinary].compactMap { $0 }
        let pid = n % 2 == 0 ? Int32(101) : Int32(102)
        let m = ObservedWindowMetadata(number: n, pid: pid, launchMicroseconds: 300, element: nil,
            globalFrame: cg, frontToBack: Int(n), minimized: minimized, fullScreen: full,
            isOnscreen: onscreen, onActiveDesktop: active, overviewSpaceID: ordinary,
            hasCatalogGeometry: geometry, overviewIsPresented: shown, overviewOrdinaryRole: role,
            activeFullscreenSpaceID: space, matchesNativeTile: tile)
        return .init(id: "\(pid)/300/\(n)", displayID: display.id, bounds: local,
            membership: membership ?? (ids.isEmpty ? .unknown : .known(recordIDs: ids)), confidence: .unknown, metadata: m)
    }
    func sample(_ windows: [WindowObservation], ordinary: Bool = false, ax: AXReadStatus = .available) -> DesktopSnapshot {
        let request = DesktopReadRequest(session: UUID(), revision: 9, parentPID: 1, fixtureWindows: nil,
                                         anchors: [], experimentalSpaces: false)
        return .observed(request, from: date, to: date, build: "fixture", topology: "two", consistent: true,
            separateSpaces: true, displays: [userDisplay, otherDisplay], scopes: [
                .init(id: "one", displayID: userDisplay.id, records: [
                    .init(id: "7", isCurrent: true, ordinaryUUID: ordinary ? ordinaryUUID : nil,
                          fullscreenUUID: ordinary ? nil : fullUUID),
                    .init(id: "6", isCurrent: false, ordinaryUUID: UUID())]),
                .init(id: "two", displayID: otherDisplay.id, records: [
                    .init(id: "8", isCurrent: true, ordinaryUUID: otherUUID)])],
            windows: windows, evidence: .init(population: .workWindows, accessibility: ax, spaces: .observed,
                rows: [], windowLimitReached: false, beganUptime: 3, endedUptime: 3.5, catalogComplete: true))
    }
    func split(_ s: DesktopSnapshot) -> NativeSplitViewLayout? {
        s.currentSplitView(on: userDisplay.id, now: date, uptime: 4)
    }
    func active(_ s: DesktopSnapshot) -> [WindowObservation] {
        s.activeSpaceWindows(on: userDisplay.id, now: date, uptime: 4)
    }

    @Test func exactSystemTilesKeepUnequalWidthsDividerAndDisplayCoordinates() throws {
        let a = window(22, left, full: false), b = window(21, right, full: nil)
        let other = window(23, .init(width: 600, height: 360), on: otherDisplay, space: nil, ordinary: "8", full: false, tile: nil)
        let s = sample([other, b, a])
        let decoded = try JSONDecoder().decode(DesktopSnapshot.self, from: JSONEncoder().encode(s))
        #expect(decoded.isStructurallyValid)
        let pair = try #require(split(decoded))
        #expect(pair.left == a && pair.right == b)
        #expect(pair.displayID == userDisplay.id && pair.spaceID == "7" && pair.spaceUUID == fullUUID)
        #expect(pair.displayFrame == userDisplay.frame && pair.leftFrame == left && pair.rightFrame == right)
        #expect(active(decoded) == [b, a])
        #expect(decoded.activeSpaceWindows(on: otherDisplay.id, now: date, uptime: 4) == [other])
        #expect(decoded.currentSplitView(on: otherDisplay.id, now: date, uptime: 4) == nil)
        #expect(decoded.currentDesktopWindows(on: userDisplay.id, now: date, uptime: 4).isEmpty)
        #expect(!a.canRequestCurrentDesktopFocus && !a.canWitnessCurrentSpace)
        #expect(!s.capabilities.windowActivation && !s.capabilities.spaceSwitching)
    }

    @Test func ordinarySideBySideAndSingleFullscreenRemainIndependentWindows() {
        let a = window(22, left, space: nil, ordinary: "7", full: false, tile: nil)
        let b = window(21, right, space: nil, ordinary: "7", full: false, tile: nil)
        let background = window(24, left, space: nil, membership: .known(recordIDs: ["6"]), full: false, tile: nil)
        let current = sample([a, b, background], ordinary: true)
        #expect(active(current) == [b, a])
        #expect(split(current) == nil)
        let single = window(23, .init(width: 1200, height: 800), tile: nil)
        #expect(active(sample([single])) == [single])
        #expect(split(sample([single])) == nil)
    }

    @Test func absentManagerRequiresTwoAXFullscreenRolesCompleteGeometryAndNoAmbiguousThirdSurface() {
        let a = window(22, left, tile: nil), b = window(21, right, tile: nil)
        #expect(split(sample([a, b])) != nil)
        for other in [
            window(21, right, full: false, tile: nil), window(21, right, full: nil, tile: nil),
            window(21, right, tile: false), window(21, right, geometry: false),
            window(21, right, tile: nil, role: nil), window(21, right, tile: nil, minimized: nil),
            window(21, right, tile: nil, onscreen: false), window(21, right, tile: nil, shown: false),
            window(21, .init(x: 430, y: 0, width: 770, height: 800), tile: nil),
            window(21, .init(x: 550, y: 0, width: 650, height: 800), tile: nil),
            window(21, .init(x: 452, y: 0, width: 748, height: 700), tile: nil),
            window(21, .init(x: 452, y: 0, width: 820, height: 800), tile: nil)
        ] { #expect(split(sample([a, other])) == nil) }
        let unresolved = window(24, left, space: nil, tile: nil, role: nil)
        #expect(split(sample([a, b, unresolved])) == nil)
        let background = window(24, left, space: nil, membership: .known(recordIDs: ["6"]), tile: nil, role: nil)
        #expect(split(sample([a, b, background])) != nil)
        #expect(split(sample([a, b, window(24, left, tile: nil)])) == nil)
    }

    @Test func untrustedStaleWrongSpaceAndLinkedScreensCannotPublishATilePair() {
        let a = window(22, left), b = window(21, right), s = sample([a, b])
        #expect(split(sample([a, b], ax: .denied)) == nil)
        #expect(s.currentSplitView(on: userDisplay.id, now: date, uptime: 24) == nil)
        #expect(s.currentSplitView(on: userDisplay.id, now: date.addingTimeInterval(30), uptime: 4) == nil)
        #expect(!sample([a, window(21, right, space: "6")]).isStructurallyValid)
        #expect(!sample([a, window(21, right, membership: .known(recordIDs: ["6","7"]))]).isStructurallyValid)
        #expect(!sample([a, window(21, right, on: otherDisplay)]).isStructurallyValid)
        var repeatedID = s
        repeatedID.scopes[1] = .init(id: "two", displayID: otherDisplay.id,
                                     records: [.init(id: "8", isCurrent: true, fullscreenUUID: fullUUID)])
        #expect(split(repeatedID) == nil)
        var linked = s
        linked.separateSpaces = false
        #expect(split(linked) == nil && active(linked).isEmpty)
    }

    @Test func linkedDisplaysUseOnlyTwicePubliclyActiveOrdinaryWindowsWhollyOnTheirPhysicalScreen() {
        func item(_ n: UInt32, _ f: SurfaceRect = .init(x: 10, y: 20, width: 160, height: 80),
                  display: DisplayObservation? = nil, role: Bool? = true, full: Bool? = false,
                  shown: Bool = true, onscreen: Bool = true, active: Bool = true, geometry: Bool = true) -> WindowObservation {
            window(n, f, on: display, space: nil, full: full, tile: nil, geometry: geometry,
                   role: role, shown: shown, onscreen: onscreen, active: active)
        }
        let first = item(11), second = item(12)
        let other1 = item(17, display: otherDisplay), other2 = item(18, display: otherDisplay)
        let unverified = [item(21, active: false), item(22, onscreen: false), item(23, shown: false), item(24, role: nil),
                          item(25, full: true), item(26, geometry: false),
                          item(27, .init(x: 1150, y: 80, width: 150, height: 400))]
        for linked: Bool? in [false, nil] {
            var s = sample([first, other2, second, other1] + unverified)
            s.separateSpaces = linked
            s.scopes = []
            s.native?.spaces = .disabled
            #expect(s.isStructurallyValid)
            #expect(s.activeSpaceWindows(on: userDisplay.id, now: date, uptime: 4) == [first, second])
            #expect(s.activeSpaceWindows(on: otherDisplay.id, now: date, uptime: 4) == [other1, other2])
            #expect(s.currentSplitView(on: userDisplay.id, now: date, uptime: 4) == nil)
        }
    }

    @Test func catalogueMapUsesCurrentPresentedRectsAndRetainsUnknownPhysicalOcclusion() throws {
        let a = window(22, left, space: nil, ordinary: "7", full: false, tile: nil)
        let oldFrame = window(23, right, space: nil, ordinary: "7", full: false, tile: nil, geometry: false)
        let hidden = window(24, right, space: nil, ordinary: "7", full: false, tile: nil, shown: false)
        let foreign = window(25, left, space: nil, membership: .known(recordIDs: ["6"]), full: false, tile: nil)
        let unknown = window(20, left, space: nil, full: false, tile: nil, role: nil)
        let s = sample([oldFrame, foreign, a, unknown, hidden], ordinary: true)
        let preview = try #require(DesktopPreview(snapshot: s, displayID: userDisplay.id,
            viewport: .init(width: 1200, height: 780), now: date, uptime: 4, restrictToDisplay: true))
        let row = try #require(preview.rows.first)
        #expect(row.windows.map(\.id) == [a.id] && row.hasUnassignedWindows)
        #expect(preview.hit(x: 60, y: 100, current: s, now: date, uptime: 4) == .blocked(unknown.id))
        #expect(preview.presentedWindow(atX: 60, y: 100, now: date, uptime: 4) == nil)
    }
}
