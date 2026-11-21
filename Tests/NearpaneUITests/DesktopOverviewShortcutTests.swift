import Carbon.HIToolbox
import NearpaneCore
import Testing
@testable import NearpaneUI

@MainActor struct DesktopOverviewShortcutTests {
    @Test func enabledSystemArrowReservesItsFunctionKeyVariant() {
        let mask = UInt32(controlKey)
        let row: [String: Any] = ["kHISymbolicHotKeyEnabled": true, "kHISymbolicHotKeyCode": kVK_UpArrow,
                                  "kHISymbolicHotKeyModifiers": mask | UInt32(kEventKeyModifierFnMask)]
        #expect(DesktopOverviewShortcut.systemReserves(mask, in: [row]))
        #expect(!DesktopOverviewShortcut.systemReserves(mask | UInt32(cmdKey), in: [row]))
        #expect(!DesktopOverviewShortcut.systemReserves(mask, in: [row.merging(["kHISymbolicHotKeyEnabled": false]) { _, new in new }]))
    }

    @MainActor private final class Fixture {
        var eligible = true
        var reserved: DesktopOverviewShortcut.Reservation = .available
        var claimSucceeds = true
        var openSucceeds = true
        var opens = 0
        var releases = 0
        var claims = [OverviewShortcutChoice]()
        var events = [() -> Bool]()
        lazy var shortcut = DesktopOverviewShortcut(reservation: { [unowned self] _ in reserved },
            register: { [unowned self] choice, id, press in
                claims.append(choice)
                guard claimSucceeds else { return nil }
                events.append { press(id) }
                return { [unowned self] in releases += 1 }
            })

        func start(_ choice: OverviewShortcutChoice = .nearpane) {
            shortcut.start(choice, eligible: { [unowned self] in eligible }, open: { [unowned self] in
                opens += 1
                return openSucceeds
            })
        }
    }

    @Test func handoffReleasesOneClaimAndRequiresANewKeyGeneration() {
        let f = Fixture()
        f.eligible = false
        f.start()
        #expect(f.claims.isEmpty)
        f.eligible = true
        f.shortcut.refreshOwnership()
        f.shortcut.refreshOwnership()
        #expect(f.claims == [.nearpane])
        let first = f.events[0]
        #expect(first() && f.opens == 1)
        f.eligible = false
        #expect(!first())
        #expect(f.releases == 1 && !f.shortcut.registered)
        f.shortcut.configure(.controlUp)
        #expect(f.claims.count == 1)
        f.eligible = true
        f.shortcut.refreshOwnership()
        #expect(f.claims == [.nearpane, .controlUp])
        #expect(!first() && f.opens == 1)
        #expect(f.events[1]() && f.opens == 2)
        f.shortcut.stop()
        #expect(f.releases == 2 && !f.events[1]())
        f.shortcut.refreshOwnership()
        #expect(!f.shortcut.registered)
    }

    @Test func aNewSystemReservationOrUnreadableInventoryNeverDispatches() {
        let f = Fixture()
        f.start(.controlUp)
        let originalPress = f.events[0]
        f.reserved = .system
        #expect(!originalPress())
        #expect(f.releases == 1 && f.opens == 0)
        f.reserved = .unknown
        f.shortcut.refreshOwnership(recheckReservation: true)
        #expect(f.claims.count == 1 && !f.shortcut.registered)
        f.reserved = .available
        f.shortcut.refreshOwnership(recheckReservation: true)
        #expect(f.claims.count == 2 && f.shortcut.registered)
        #expect(!originalPress())
        f.shortcut.configure(.off)
        #expect(f.releases == 2 && !f.events[1]())
    }

    @Test func aRejectedClaimWaitsForARealChangeOrExplicitRetry() {
        let f = Fixture()
        f.claimSucceeds = false
        f.start()
        f.shortcut.refreshOwnership()
        #expect(!f.shortcut.registered && f.claims.count == 1)
        f.claimSucceeds = true
        f.shortcut.refreshOwnership(recheckReservation: true)
        #expect(f.shortcut.registered && f.claims.count == 2)
        f.openSucceeds = false
        #expect(!f.events[0]())
        #expect(f.opens == 1 && f.releases == 0)
        f.shortcut.stop()
    }
}
