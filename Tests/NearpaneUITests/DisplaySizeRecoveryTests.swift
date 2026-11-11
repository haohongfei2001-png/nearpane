import NearpaneCore
import Testing
@testable import NearpaneUI

@MainActor struct DisplaySizeRecoveryTests {
    private let safe = SurfaceRect(x: -800, width: 800, height: 1280)
    @Test func localResetKeepsIndependentReservationAndScreenIntent() throws {
        let screen = ScreenGeometry(id: "side", frame: safe, visibleFrame: safe)
        var config = DisplaySettings()
        config.placement = .floating
        config.spacesDismissed = true
        config.floatingPosition = .init(x: 5, y: 6)
        config.measures = [.voiceHeight: .init(320), .textSize: .init(18), .reservedWidth: .init(170), .cellWidth: .init(70)]
        let reset = DisplaySizeReset(screen: screen, saved: config, group: .voice)
        let voice = try #require(reset.applying(to: config, on: screen))
        #expect(voice.measures == [.reservedWidth: .init(170), .cellWidth: .init(70)])
        let all = try #require(DisplaySizeReset(screen: screen, saved: voice, group: nil).applying(to: voice, on: screen))
        var expected = config
        expected.measures = [:]
        #expect(all == expected)
        #expect(reset.applying(to: voice, on: screen) == nil)
    }

    @Test func rotatedDetachedOrAmbiguousDisplayCannotCommitPendingEdit() {
        let portrait = ScreenGeometry(id: "side", frame: safe, visibleFrame: safe, rotationDegrees: 90)
        let landscape = ScreenGeometry(id: "side", frame: safe, visibleFrame: safe, rotationDegrees: 0)
        var saved = DisplaySettings()
        saved.measures[.reservedWidth] = .init(160)
        let draft = DisplaySizeReset(screen: portrait, saved: saved, group: .panel)
        let inventory = SettingsScreenInventory()
        for current in [[portrait], [landscape], [], [portrait, portrait]] {
            inventory.update(current)
            #expect(inventory.contains(portrait) == (current == [portrait]))
        }
        #expect(draft.applying(to: saved, on: landscape) == nil)
    }
}
