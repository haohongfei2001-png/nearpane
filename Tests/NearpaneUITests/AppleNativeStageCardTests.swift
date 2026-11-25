import Foundation
import NearpaneCore
import Testing
@testable import NearpaneUI

@MainActor struct AppleNativeStageCardTests {
    @Test func rapidThirdCardChoiceWaitsForTwoFreshReadsOfThePreviousExactFocus() {
        typealias Group = AppleNativeStages.Group
        let keys = (0..<3).map { DesktopWindowKey(pid: 10, birth: 500, number: UInt32($0 + 1)) }
        func roster(current: Int) -> [Group] {
            keys.enumerated().map { index, key in Group(id: String(index), current: index == current, members: [key],
                                             evidence: index == current ? .currentWindowList : .nativeStripItem) }
        }
        let original = roster(current: 0), previous = roster(current: 1), foreign = roster(current: 2)
        @MainActor final class Focus { var exact = false }
        let focus = Focus()
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        let handoff = AppleStageSelectionHandoff(roster: original, target: original[1], focusMatches: { focus.exact },
            ownsForeground: { true }, release: {}, deadline: deadline)
        #expect(handoff.includes(original[2]))
        #expect(!handoff.includes(original[2], now: deadline))
        #expect(handoff.permits(original))
        #expect(!handoff.focused(original))
        #expect(!handoff.permits(foreign))
        let recycled = Group(id: original[2].id, current: false, members: [.init(pid: 10, birth: 501, number: 3)])
        #expect(!handoff.includes(recycled))
        var reads = AppleStageSelectionHandoff.Confirmations(after: 15)
        func record(_ stamp: UInt64, _ groups: [Group]) -> Bool { reads.record(stamp, exact: handoff.focused(groups)) }
        #expect(!record(16, previous))
        focus.exact = true
        #expect(!record(17, previous))
        #expect(!record(17, previous))
        #expect(!record(18, foreign))
        #expect(!record(19, previous))
        #expect(record(20, previous))
    }

    @Test func aConfirmedNativeFocusDoesNotPromoteHistoricalPeers() {
        let a = DesktopWindowKey(pid: 10, birth: 200, number: 1)
        let b = DesktopWindowKey(pid: 20, birth: 400, number: 2)
        let old = AppleNativeStages.Group(id: "a", current: true, members: [a], evidence: .currentWindowList)
        let known = AppleNativeStages.Group(id: "b", current: false, members: [b], evidence: .remembered)
        let handoff = AppleStageSelectionHandoff(roster: [old, known], target: known, focusMatches: { true },
            ownsForeground: { true }, release: {}, deadline: .now.advanced(by: .seconds(4)))
        #expect(handoff.includes(known))
        #expect(!handoff.originalMembershipConfirmed)
        let prior = AppleNativeStages.Group(id: "a", current: false, members: [a], evidence: .remembered)
        var front = AppleNativeStages.Group(id: "b", current: true, members: [b], evidence: .unsettled)
        #expect(!handoff.focused([prior, front]))
        front.evidence = .currentWindowList
        #expect(handoff.focused([prior, front]))
        var reads = AppleStageSelectionHandoff.OutcomeConfirmations(after: 50)
        #expect(reads.record(51, focused: true, preserved: false) == nil)
        #expect(reads.record(51, focused: true, preserved: true) == nil)
        #expect(reads.record(52, focused: true, preserved: true) == .focusedGroup)
        #expect(reads.record(53, focused: true, preserved: true) == .preservedRoster)
        #expect(reads.record(54, focused: false, preserved: true) == nil)
    }

    @Test func onlyTheCurrentLocalDragCanMergeTheExactWindowsOnItsOriginalDesktop() async throws {
        let drag = AppleNativeStageDrag(), now = ContinuousClock.now, intent = UUID()
        let scope = AppleNativeStageDrag.Scope(session: UUID(), display: "display", desktop: UUID(), record: "4", topology: "one")
        let a = DesktopWindowKey(pid: 20, birth: 100, number: 10), b = DesktopWindowKey(pid: 20, birth: 100, number: 11)
        let source = AppleNativeStages.Group(id: "a", current: false, members: [a])
        let destination = AppleNativeStages.Group(id: "b", current: true, members: [b])
        let groups = [source, destination]
        var appearances = [a: UUID(), b: UUID()]
        func start() throws -> AppleStageDragTicket {
            try #require(drag.begin(source, scope: scope, intent: intent, groups: groups, lifetime: { appearances[$0] }, now: now))
        }
        func take(_ ticket: AppleStageDragTicket, to target: AppleNativeStages.Group? = nil,
                  in home: AppleNativeStageDrag.Scope? = nil, selection: UUID? = nil,
                  roster: [AppleNativeStages.Group]? = nil, at time: ContinuousClock.Instant? = nil) -> AppleNativeStages.Group? {
            drag.consume(ticket, into: target ?? destination, scope: home ?? scope, intent: selection ?? intent,
                         groups: roster ?? groups, lifetime: { appearances[$0] }, now: time ?? now)
        }
        let stale = try start(), live = try start()
        let provider = live.provider()
        #expect(provider.registeredTypeIdentifiers == [AppleStageDragTicket.type.identifier])
        let ordinaryText = NSItemProvider(object: NSString(string: live.nonce.uuidString))
        #expect(!ordinaryText.hasItemConformingToTypeIdentifier(AppleStageDragTicket.type.identifier))
        let delivered: AppleStageDragTicket = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadTransferable(type: AppleStageDragTicket.self) { continuation.resume(with: $0) }
        }
        #expect(delivered.nonce == live.nonce)
        #expect(take(stale) == nil)
        #expect(take(live) == source)
        #expect(take(live) == nil)
        #expect(try take(start(), to: source) == nil)
        #expect(try take(start(), selection: UUID()) == nil)
        let foreign = AppleNativeStageDrag.Scope(session: scope.session, display: scope.display, desktop: UUID(),
                                                 record: "5", topology: scope.topology)
        #expect(try take(start(), in: foreign) == nil)
        #expect(try take(start(), at: now.advanced(by: .seconds(61))) == nil)
        #expect(try take(start(), roster: [destination]) == nil)
        let recycled = try start()
        appearances[a] = UUID()
        #expect(take(recycled) == nil)
        let cancelled = try start()
        drag.cancel()
        #expect(take(cancelled) == nil)
    }

    @Test func aStripThumbnailCannotReplaceTheOriginalLayoutOfEitherDocument() throws {
        let display = DisplayObservation(id: "display", frame: .init(x: 300, y: 0, width: 900, height: 700),
            rotationDegrees: 0, backingScale: 2, usable: nil)
        let original = SurfaceRect(x: 500, y: 120, width: 550, height: 400)
        let strip = SurfaceRect(x: 310, y: 30, width: 75, height: 40)
        let key = DesktopWindowKey(pid: 400, birth: 800, number: 20), lifetime = UUID()
        func row(_ bounds: SurfaceRect, logical: SurfaceRect?) -> WindowObservation {
            .init(id: "document", displayID: display.id, bounds: bounds, membership: .known(recordIDs: ["4"]), confidence: .unknown,
                metadata: .init(number: key.number, pid: key.pid, launchMicroseconds: key.birth, element: nil, globalFrame: bounds,
                    frontToBack: 0, minimized: false, fullScreen: false, axFrame: bounds, isOnscreen: true,
                    axStandardWindowNumber: key.number, onActiveDesktop: true, hasCatalogGeometry: true, catalogLogicalFrame: logical))
        }
        let active = AppleNativeStageCard.layoutFrames([key], currentStage: true, screen: display,
            rows: [key: row(original, logical: nil)], retained: [:], lifetime: { _ in lifetime })
        #expect(active[key]?.frame == original)
        let inactive = [key: row(strip, logical: nil)]
        #expect(AppleNativeStageCard.layoutFrames([key], currentStage: false, screen: display, rows: inactive,
            retained: active, lifetime: { _ in lifetime })[key]?.frame == original)
        #expect(AppleNativeStageCard.layoutFrames([key], currentStage: false, screen: display, rows: inactive,
            retained: active, lifetime: { _ in UUID() }).isEmpty)
        #expect(AppleNativeStageCard.fullFrame(row(strip, logical: original), currentStage: false, on: display) == original)
    }
}
