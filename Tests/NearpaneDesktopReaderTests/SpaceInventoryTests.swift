import Foundation
import Testing
import NearpaneCore
import WindowGeometryCore
@testable import NearpaneDesktopReader

struct SpaceInventoryTests {
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
