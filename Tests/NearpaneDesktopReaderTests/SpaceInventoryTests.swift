import Foundation
import Testing
import NearpaneCore
import WindowGeometryCore
@testable import NearpaneDesktopReader

struct SpaceInventoryTests {
    @Test func rosterRequiresOrderingIndependentlyOfSpaceMembership() {
        func shown(active: Bool = false, ordered: Bool = false, member: Bool = true,
                   onDisplay: Bool = true, unhidden: Bool = true,
                   ax: Bool = false, role: OverviewWindowRole? = nil, staged: Bool = false) -> Bool {
            Reader.presentedInOverview(publiclyVisible: active, orderedAcrossSpaces: ordered,
                currentMember: member, onDisplay: onDisplay, ownerUnhidden: unhidden, readsAX: ax, role: role, drawnInStage: staged)
        }
        let ordinary = OverviewWindowRole(ordinary: true, minimized: false, fullscreen: false)
        #expect(shown(active: true))
        #expect(!shown(ordered: true)) // all-Spaces ordering does not attest a non-minimized document
        #expect(!shown(ordered: true, staged: true))
        #expect(shown(ordered: true, ax: true, role: ordinary))
        #expect(shown(ax: true, role: ordinary, staged: true))
        #expect(!shown(staged: true))
        #expect(!shown(member: false, ax: true, role: ordinary, staged: true))
        #expect(!shown())  // An ordered-out window still has its old Space membership.
        #expect(!shown(ax: true, role: ordinary))
        #expect(!shown(ordered: true, member: false))
        #expect(!shown(active: true, onDisplay: false))
        #expect(!shown(active: true, unhidden: false))
        #expect(!shown(active: true, ax: true, role: nil))
        for ineligible in [OverviewWindowRole(ordinary: true, minimized: true, fullscreen: false),
                           .init(ordinary: false, minimized: false, fullscreen: false),
                           .init(ordinary: true, minimized: nil, fullscreen: false),
                           .init(ordinary: true, minimized: false, fullscreen: true)] {
            #expect(!shown(active: true, ordered: true, ax: true, role: ineligible))
            #expect(!shown(active: true, ordered: true, role: ineligible))
        }
    }

    @Test func stableStageStripCGDoesNotReplaceTheLogicalWindowFrame() {
        // Both rectangles were stable across four samples of the same owned window on 26A428.
        let strip = Rect(1302, 756, 152, 141), owned = Rect(465, 388, 540, 213)
        let staged = Reader.catalogGeometry(firstLogical: owned, lastLogical: owned, firstCG: strip, lastCG: strip,
                                             stageDefinitelyOff: false)
        #expect(staged.logical == owned && !staged.usualPresentation)
        let visible = Reader.catalogGeometry(firstLogical: owned, lastLogical: owned, firstCG: owned, lastCG: owned,
                                              stageDefinitelyOff: false)
        #expect(visible.logical == owned && visible.usualPresentation)
        let unsupported = Reader.catalogGeometry(firstLogical: nil, lastLogical: nil, firstCG: strip, lastCG: strip,
                                                  stageDefinitelyOff: false)
        #expect(unsupported.logical == nil && !unsupported.usualPresentation)
        let changing = Reader.catalogGeometry(firstLogical: owned, lastLogical: strip, firstCG: strip, lastCG: strip,
                                               stageDefinitelyOff: true)
        #expect(changing.logical == nil && !changing.usualPresentation)
        let ordinary = Reader.catalogGeometry(firstLogical: nil, lastLogical: nil, firstCG: owned, lastCG: owned,
                                               stageDefinitelyOff: true)
        #expect(ordinary.usualPresentation)
    }
    @Test func windowDisplayNeedsStableOwnershipAcrossSamplesAndUnambiguousTies() throws {
        let left = Rect(0, 0, 800, 600), right = Rect(800, 0, 800, 600)
        let geometry = try DesktopGeometry(displays: [
            .init(displayID: "left", appKitFrame: left, cgBounds: left, backingScale: 2, rotation: .zero),
            .init(displayID: "right", appKitFrame: right, cgBounds: right, backingScale: 1, rotation: .zero)
        ], primaryID: "left")
        let a = try geometry.slices(of: Rect(100, 40, 400, 320))
        let b = try geometry.slices(of: Rect(1100, 40, 400, 320))
        let split = try geometry.slices(of: Rect(600, 40, 400, 320))
        #expect(Reader.overviewDisplay(before: a, after: b, memberDisplays: ["right"]) == nil)
        #expect(Reader.overviewDisplay(before: b, after: b, memberDisplays: []) == "right")
        #expect(Reader.overviewDisplay(before: split, after: split, memberDisplays: []) == nil)
        #expect(Reader.overviewDisplay(before: split, after: split, memberDisplays: ["right"]) == "right")
        #expect(Reader.overviewDisplay(before: [], after: [], memberDisplays: ["left","right"]) == nil)
        #expect(Reader.overviewDisplay(before: [], after: [], memberDisplays: ["right"]) == "right")
    }

    let id = "12000000-0000-0000-0000-000000000001"
    var displays: [DisplayObservation] { [.init(id: id, frame: .init(width: 800, height: 1280), rotationDegrees: 90, backingScale: 2)] }
    func scope(_ records: [Any], current: Any = 5) -> [[String: Any]] {
        [["Display Identifier": id, "Current Space": ["id64": current], "Spaces": records]]
    }
    let records: [[String: Any]] = [["id64": 5, "type": 0], ["id64": 9, "type": 4]]

    @Test func ordinaryCandidatesPreserveDisplayAndUnfilteredRecordOrder() throws {
        let raw = records + [["id64": 12, "type": 91], ["id64": 8, "type": 0]]
        let inventory = try #require(SpaceInventory(scope(raw), displays: displays))
        #expect(inventory.ordinaryRecordsByDisplay == [id: ["5", "8"]])
        #expect(inventory.scopes[0].records.map(\.id) == ["5", "9", "12", "8"])
    }

    @Test func onlyValidatedOrdinaryUUIDsCanIdentifyARecordAcrossVisits() throws {
        let uuid = UUID()
        let inventory = try #require(SpaceInventory(scope([
            ["id64": 5, "type": 0, "uuid": uuid.uuidString],
            ["id64": 6, "type": 4, "uuid": UUID().uuidString],
            ["id64": 7, "type": 0, "uuid": "unavailable"]
        ]), displays: displays))
        #expect(inventory.scopes[0].records.map(\.ordinaryUUID) == [uuid, nil, nil])
    }

    @Test func membershipKeepsMultipleIDsAndEmptyOrInvalidIsUnknown() throws {
        let inventory = try #require(SpaceInventory(scope(records), displays: displays))
        #expect(inventory.membership([9,5]) == .known(recordIDs: ["5","9"]))
        for value: Any in [[], [5,5], [11], [true], ["5"], [5.1], [-1]] {
            #expect(inventory.membership(value) == .unknown)
        }
        #expect(inventory.scopes[0].records.map(\.isCurrent) == [true,false])
    }
    @Test func unknownDisplayMalformedCurrentAndReusedIDsRejectInventory() {
        #expect(SpaceInventory(scope(records, current: 7), displays: displays) == nil)
        #expect(SpaceInventory(scope(records + [records[0]]), displays: displays) == nil)
        #expect(SpaceInventory(scope(records), displays: []) == nil)
        #expect(SpaceInventory(scope(records) + scope(records), displays: displays) == nil)
        #expect(SpaceInventory(scope([["id64": true, "type": 0]]), displays: displays) == nil)
    }
}

extension SpaceInventoryTests {
    @Test func currentSpaceNeedsAnIndependentWitnessAndExactOrderedMembership() throws {
        let d = displays[0], inventory = try #require(SpaceInventory(scope(records), displays: displays))
        let frame = SurfaceRect(x: 20, y: 30, width: 80, height: 80)
        let a = ActiveSpaceAnchor(number: 6, displayID: id, globalFrame: frame)
        let window = CGWindowMetadata(process: .init(pid: 205, launchEpochMicroseconds: 47), windowID: 6,
                                      title: nil, frame: frame.geometry)
        func rows(_ members: WindowMembership, _ witnesses: [ActiveSpaceAnchor], parent: Int32 = 205,
                  complete: Bool = true, screens: [DisplayObservation]? = nil, independent: Bool = true) -> [ObservedSpaceRow] {
            SpaceBoundary(inventory: inventory, membership: [6: members]).confirmedRows(displays: screens ?? [d],
                separateSpaces: independent, complete: complete, candidates: witnesses, windows: [window], parent: parent)
        }
        let known = WindowMembership.known(recordIDs: ["5"])
        #expect(rows(known, [a]).map(\.recordID) == ["5"])
        #expect(rows(known, []).isEmpty && rows(.unknown, [a]).isEmpty)
        #expect(rows(.known(recordIDs: ["5","9"]), [a]).isEmpty)
        #expect(rows(.known(recordIDs: ["9"]), [a]).isEmpty)
        #expect(rows(known, [a], parent: 206).isEmpty && rows(known, [a], complete: false).isEmpty)
        #expect(rows(known, [a], screens: [d,d], independent: false).isEmpty)
        let rebuilt = ActiveSpaceAnchor(number: 7, displayID: id, globalFrame: frame)
        let moved = ActiveSpaceAnchor(number: 6, displayID: id, globalFrame: .init(x: 30, y: 30, width: 80, height: 80))
        #expect(rows(known, [rebuilt, moved]).isEmpty)
        let foreign = ActiveSpaceAnchor(number: 6, displayID: id, globalFrame: frame, witness: .appKitActiveList)
        #expect(rows(known, [foreign], parent: 206).count == 1 && rows(known, [foreign]).isEmpty)
    }
}
