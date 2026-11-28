import Foundation
import Testing
import NearpaneCore
import WindowGeometryCore
@testable import NearpaneDesktopReader

struct NativeTileInventoryTests {
    let displayID = "12000000-0000-0000-0000-000000000001"
    let uuid = UUID()
    var display: DisplayObservation {
        .init(id: displayID, frame: .init(width: 1000, height: 600), rotationDegrees: 0,
              backingScale: 2, usable: .init(width: 1000, height: 600))
    }
    func tile(_ pid: Any, _ wid: Any, _ x: Double, _ w: Any) -> [String: Any] {
        ["pid": pid, "TileWindowID": wid, "TileRect": ["X": x,"Y": 0,"Width": w,"Height": 600] as [String: Any]]
    }
    var a: [String: Any] { tile(28, 450, 0, 330) }
    var b: [String: Any] { tile(29, 451, 342, 658) }
    func space(_ tiles: [[String: Any]]? = nil, type: Any = 4) -> [String: Any] {
        var space: [String: Any] = ["id64": 7, "uuid": uuid.uuidString, "type": type]
        if let tiles { space["TileLayoutManager"] = ["TileSpaces": tiles] }
        return space
    }
    func inventory(_ listRow: [String: Any], current: [String: Any]? = nil) -> SpaceInventory? {
        let row: [String: Any] = ["Display Identifier": displayID, "Current Space": current ?? ["id64": 7],
                                  "Spaces": [listRow, ["id64": 10, "uuid": UUID().uuidString, "type": 0]]]
        return .init([row], displays: [display])
    }
    @Test func tileFramesKeepTheSystemAsymmetricDividerAndExactOwners() throws {
        let parsed = try #require(inventory(space([b, a]), current: space([a, b])))
        #expect(parsed.activeTiles["7"] == [.init(pid: 28, number: 450, frame: .init(0, 0, 330, 600)),
                                             .init(pid: 29, number: 451, frame: .init(342, 0, 658, 600))])
        #expect(parsed.scopes.first?.records.first?.nativeKind == .fullscreen)
        #expect(inventory(space())?.activeTiles.isEmpty == true)
        #expect(inventory(space(), current: space([a,b]))?.activeTiles == parsed.activeTiles)
        #expect(inventory(space([a,b], type: 0))?.activeTiles.isEmpty == true)
    }

    @Test func malformedManagerIsKeptDistinctFromMissingManager() throws {
        for wrong in [[a], [a,b,b], [a,a], [a,tile(29, true, 330, 658)], [a,tile(29.5, 451, 330, 658)],
                      [a,tile(29, 451, 330, true)], [a,tile(29, 451, 330, Double.nan)],
                      [a,tile(0, 451, 330, 658)], [a,tile(29, 0, 330, 658)]] {
            let parsed = try #require(inventory(space(wrong)))
            #expect(parsed.activeTiles["7"] == [])
        }
        #expect(inventory(space([a,b]), current: space([a,tile(30, 451, 342, 658)]))?.activeTiles["7"] == [])
        #expect(inventory(space([a,b]), current: ["id64": 7, "type": 0]) == nil)
        #expect(inventory(space([a,b]), current: ["id64": 7, "uuid": UUID().uuidString]) == nil)
    }

    @Test func onlyWellFormedForwardReadOfThisCurrentFullscreenSpaceCanAuthorizeAMember() throws {
        let catalog = try #require(inventory(space()))
        var queried: [UInt64] = []
        let correct = catalog.fullscreenMembers { id in queried.append(id); return [450, 451] }
        #expect(queried == [7] && correct == ["7": [450,451]])
        for missing: [NSNumber]? in [nil, [true, 451], [0], [450, 450], [2.25], [-1]] {
            #expect(catalog.fullscreenMembers { _ in missing }.isEmpty)
        }
        #expect(catalog.fullscreenMembers { _ in [] } == ["7": []])
        queried = []
        let ordinary = try #require(inventory(space(type: 0)))
        #expect(ordinary.fullscreenMembers { id in queried.append(id); return [450] }.isEmpty && queried.isEmpty)
    }

    @Test func soleNativeOwnerCanDisambiguateAStraddlingWindowButCannotMoveACardToAnotherDisplay() throws {
        let l = Rect(0, 0, 800, 600), r = Rect(800, 0, 800, 600)
        let geometry = try DesktopGeometry(displays: [
            .init(displayID: "A", appKitFrame: l, cgBounds: l, backingScale: 2, rotation: .zero),
            .init(displayID: "B", appKitFrame: r, cgBounds: r, backingScale: 1, rotation: .zero)
        ], primaryID: "A")
        let both = try geometry.slices(of: Rect(760, 50, 300, 240))
        let onlyB = try geometry.slices(of: Rect(960, 50, 300, 240))
        #expect(Reader.overviewDisplay(before: both, after: both, memberDisplays: ["A"]) == "A")
        #expect(Reader.overviewDisplay(before: both, after: both, memberDisplays: []) == "B")
        #expect(Reader.overviewDisplay(before: onlyB, after: onlyB, memberDisplays: ["A"]) == nil)
        #expect(Reader.overviewDisplay(before: both, after: onlyB, memberDisplays: ["A"]) == nil)
    }
}
