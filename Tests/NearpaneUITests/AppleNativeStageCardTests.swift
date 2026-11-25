import Foundation
import NearpaneCore
import Testing
@testable import NearpaneUI

@MainActor struct AppleNativeStageCardTests {
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
