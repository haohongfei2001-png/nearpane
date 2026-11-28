import AppKit
import NearpaneCore
import Testing
@testable import NearpaneUI

@MainActor struct NativeStageHistoryPixelsTests {
    @Test func nativeMemberUsesOnlyItsOriginalFrameOnItsOwnDesktop() throws {
        let fixture = StageGroupHistoryPictureTests()
        let original = fixture.snapshot(1, stage: true)
        let window = try #require(original.windows.first)
        let target = try #require(DesktopWindowTarget.preview(window, in: original))
        let pixels = try fixture.image(red: true, width: 20, height: 12)
        let appearance = UUID()
        let cache = StageGroupHistoryPictureTests.Cache()
        let gallery = DesktopWindowGallery(permitsWindow: { _ in true }, cache: cache, lifetime: { _ in appearance })
        func read(_ snapshot: DesktopSnapshot, _ ticket: UUID?, _ witnessesMatch: Bool, strip: Bool = false) -> CGImage? {
            DesktopWindowGallery.nativeStagePixels(target.key, display: target.display, snapshot: snapshot,
                cache: cache, appearance: ticket, nativeStripMember: strip) { _, record, desktop in
                    witnessesMatch && record == "4" && desktop == fixture.scope.nativeSpace
                }
        }
        var inactive = fixture.snapshot(2, stage: true)
        let m = try #require(window.metadata)
        inactive.windows[0].metadata = .init(number: m.number, pid: m.pid, launchMicroseconds: m.launchMicroseconds,
            element: nil, globalFrame: m.globalFrame, frontToBack: m.frontToBack, minimized: false, fullScreen: false,
            isOnscreen: false, onActiveDesktop: false, overviewSpaceID: "4", hasCatalogGeometry: true,
            catalogLogicalFrame: m.globalFrame, overviewIsPresented: false, overviewOrdinaryRole: true)
        #expect(DesktopWindowTarget.preview(inactive.windows[0], in: inactive) == nil)
        #expect(read(inactive, appearance, true) == nil)
        cache.store(.init(target: target, lifetime: appearance,
                          capture: .init(image: pixels, logicalSize: CGSize(width: window.bounds.width, height: window.bounds.height)),
                          time: 1), for: .current(target.key), cost: try #require(PreviewPixelBudget.charge(pixels)))
        #expect(read(inactive, appearance, true) === pixels)
        #expect(read(inactive, appearance, false) == nil)
        for minimized in [true, nil] as [Bool?] {
            var dockOrStage = inactive
            dockOrStage.windows[0].metadata?.minimized = minimized
            #expect(read(dockOrStage, appearance, true) == nil)
            #expect(read(dockOrStage, appearance, true, strip: true) === pixels)
            #expect(read(dockOrStage, appearance, false, strip: true) == nil)
        }
        #expect(read(inactive, UUID(), true) == nil)
        #expect(read(inactive, nil, true) == nil)
        #expect(read(fixture.snapshot(3, stage: true, birth: 9876), appearance, true) == nil)
        #expect(read(fixture.snapshot(4, fullscreen: true, stage: true), appearance, true) == nil)
        var changed = inactive
        changed.windows[0] = WindowObservation(id: window.id, displayID: window.displayID, bounds: window.bounds,
            membership: .known(recordIDs: ["5"]), confidence: window.confidence, metadata: inactive.windows[0].metadata)
        #expect(read(changed, appearance, true) == nil)
        changed = inactive
        changed.windows.removeFirst()
        #expect(read(changed, appearance, true) == nil)
        changed = inactive
        changed.windows.append(inactive.windows[0])
        #expect(read(changed, appearance, true) == nil)
        #expect(gallery.captureRequests == 0 && gallery.activeStreamCount == 0)
    }
}
