import AppKit
import CNearpaneWindowEngine
import Foundation
import Testing
@testable import NearpaneWindowEngine

struct AppleStageMembershipTests {
    @Test func hiddenStripAndRememberedCardsNeedFreshMembershipToConfirmTheDirectory() throws {
        let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let mirror = try #require(AppleStageMirror(display: UUID(), space: 4))
        let current = CGRect(x: 200, y: 50, width: 800, height: 650)
        let hiddenStrip = CGRect(x: -240, y: 200, width: 180, height: 120)
        let away = CGRect(x: -1400, y: -1400, width: 700, height: 550)
        func snapshot(_ stamp: UInt64, _ location: CGRect, _ items: [[UInt32]]?) -> AppleStageSystemRead {
            let strip = items.map { groups in
                [AppleStageSystemRead.Strip(frame: screen, items: groups.map {
                    AppleStageSystemRead.Item(frame: hiddenStrip, members: $0)
                })]
            }
            return AppleStageSystemRead(manager: 99, sampleTime: stamp,
                listed: [.init(window: 1, pid: 11, layer: 0, onscreen: 1, frame: .init(current)),
                         .init(window: 2, pid: 22, layer: 0, onscreen: 0, frame: .init(location))],
                strips: strip, singleDisplay: true)
        }
        func read(_ stamp: UInt64, _ location: CGRect, _ items: [[UInt32]]?) throws -> AppleStageMirror.Reading {
            try #require(mirror.read(snapshot(stamp, location, items), owners: [1:11, 2:22], screen: screen))
        }
        _ = try read(1, hiddenStrip, [[2]])
        let initial = try read(2, hiddenStrip, [[2]])
        #expect(initial.settled && initial.stripShown == false && initial.completeMembership)
        #expect(initial.stages.map(\.evidence) == [.currentWindowList, .nativeStripItem])
        // The Rust UI fold can still have its previously corroborated AX partition.
        for stamp in 3...4 {
            let missing = try read(UInt64(stamp), hiddenStrip, [])
            #expect(missing.settled && !missing.completeMembership)
            #expect(missing.stages.map(\.evidence) == [.currentWindowList, .inferredStrip])
        }
        let moving = try read(5, away, nil)
        #expect(!moving.settled && !moving.completeMembership)
        #expect(moving.stages.allSatisfy { $0.evidence == .unsettled })
        _ = try read(2_000_000_000, away, nil)
        for stamp in [UInt64(3_000_000_000), 4_000_000_000] {
            let retained = try read(stamp, away, nil)
            #expect(retained.stages.map(\.evidence) == [.currentWindowList, .remembered])
            #expect(!retained.completeMembership)
        }
        let unrepresentedPeer = try read(5_000_000_000, away, [[2, 88]])
        #expect(!unrepresentedPeer.completeMembership)
        let observedAgain = try read(6_000_000_000, away, [[2]])
        #expect(observedAgain.completeMembership)
        let conflict = try read(7_000_000_000, away, [[1],[2]])
        #expect(conflict.contradictory && !conflict.completeMembership)
        #expect(mirror.read(snapshot(8_000_000_000, hiddenStrip, [[2]]),
                           owners: [1:11, 2:99], screen: screen) == nil)
    }
}
