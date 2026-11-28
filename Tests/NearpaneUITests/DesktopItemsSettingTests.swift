import AppKit
import Testing
@testable import NearpaneUI

struct DesktopItemsSettingTests {
    typealias Read = DesktopItemsSetting.Readback<Int>
    let shown = Read(item: 1, mode: .always), hidden = Read(item: 1, mode: .onWallpaperClick)

    @Test func onePressRequiresTwoConsecutiveMatchingReadsFromTheSameCheckbox() async {
        var reads = [shown, hidden, shown, hidden, hidden], presses = [Int]()
        let outcome = await DesktopItemsSetting.apply(.onWallpaperClick, first: shown,
            read: { reads.removeFirst() }, press: { presses.append($0) }, wait: {})
        #expect(outcome == .confirmed(.onWallpaperClick) && reads.isEmpty && presses == [1])
        var restored = [hidden, shown, shown]
        let back = await DesktopItemsSetting.apply(.always, first: hidden,
            read: { restored.removeFirst() }, press: { presses.append($0) }, wait: {})
        #expect(back == .confirmed(.always) && restored.isEmpty && presses == [1, 1])
    }

    @Test func readingOrSelectingTheAlreadyAppliedModeNeverPresses() async {
        var presses = 0
        for request: DesktopItemDisplay? in [nil, .onWallpaperClick] {
            let result = await DesktopItemsSetting.apply(request, first: hidden, read: { hidden },
                press: { _ in presses += 1 }, wait: {})
            #expect(result == .confirmed(.onWallpaperClick))
        }
        #expect(presses == 0)
        let managed = Read(item: 1, mode: .always, canPress: false)
        #expect(await DesktopItemsSetting.apply(nil, first: managed, read: { managed },
            press: { _ in presses += 1 }, wait: {}) == .confirmed(.always))
        #expect(await DesktopItemsSetting.apply(.onWallpaperClick, first: managed, read: { managed },
            press: { _ in presses += 1 }, wait: {}) == .manual(.disabled))
        #expect(presses == 0)
    }

    @Test func staleSelectionNavigationOrAnAmbiguousPressNeverTogglesAgain() async {
        var presses = 0
        let stale = await DesktopItemsSetting.apply(.onWallpaperClick, first: shown, read: { hidden },
            press: { _ in presses += 1 }, wait: {})
        #expect(stale == .manual(.changed) && presses == 0)
        var reads: [Read?] = [shown, hidden, .init(item: 2, mode: .onWallpaperClick)]
        let navigated = await DesktopItemsSetting.apply(.onWallpaperClick, first: shown,
            read: { reads.removeFirst() }, press: { _ in presses += 1 }, wait: {})
        #expect(navigated == .unconfirmed && presses == 1)
        let unchanged = await DesktopItemsSetting.apply(.onWallpaperClick, first: shown, read: { shown },
            press: { _ in presses += 1 }, wait: {})
        #expect(unchanged == .unconfirmed && presses == 2)
    }

    @Test func aCheckboxMustHaveAnUnambiguousBinaryValue() {
        for one: CFTypeRef in [kCFBooleanTrue!, NSNumber(value: 1), "1" as CFString] {
            #expect(DesktopItemsSetting.boolean(one) == true)
        }
        for zero: CFTypeRef in [kCFBooleanFalse!, NSNumber(value: 0), "0" as CFString] {
            #expect(DesktopItemsSetting.boolean(zero) == false)
        }
        #expect(DesktopItemsSetting.boolean(NSNumber(value: 2)) == nil)
        #expect(DesktopItemsSetting.boolean("mixed" as CFString) == nil)
        #expect(DesktopItemsSetting.boolean(nil) == nil)
    }

    @Test func theStageManagerColumnAndWidgetRowCannotChangeDesktopFiles() {
        #expect(!DesktopItemsSetting.identifiesDesktopItems(id: "desktop-items", names: ["In Stage Manager"]))
        #expect(!DesktopItemsSetting.identifiesDesktopItems(id: "desktop-items", names: ["On Desktop"]))
        #expect(!DesktopItemsSetting.identifiesDesktopItems(id: "show-desktop-widgets", names: ["On Desktop"]))
        #expect(!DesktopItemsSetting.identifiesDesktopItems(id: "", names: ["On Desktop"]))
        #expect(!DesktopItemsSetting.identifiesDesktopItems(id: "show-items", names: []))
        #expect(DesktopItemsSetting.identifiesDesktopItems(id: "show-items", names: ["On Desktop"]))
        #expect(DesktopItemsSetting.identifiesDesktopItems(id: "show-items", names: ["桌面上"]))
        #expect(DesktopItemsSetting.identifiesDesktopItems(id: "show-items-on-desktop", names: ["桌面上"]))
    }

    @Test @MainActor func onlyTheSystemDesktopBackgroundQualifies() {
        let finder = "com.apple.finder"
        #expect(WallpaperRevealMonitor.isDesktopBackground(windowOwner: finder, hitOwner: finder, role: kAXScrollAreaRole))
        let display = CGRect(x: -1440, y: -160, width: 1440, height: 900)
        let p = CGPoint(x: -1250, y: 60)
        #expect(WallpaperRevealMonitor.coversDesktop(display.insetBy(dx: 20, dy: 30), display: display, at: p))
        #expect(!WallpaperRevealMonitor.coversDesktop(CGRect(origin: p, size: .init(width: 64, height: 64)), display: display, at: p))
        #expect(WallpaperRevealMonitor.isDesktopBackground(windowOwner: finder, hitOwner: finder, role: kAXGroupRole, fullDesktopGroup: true))
        #expect(!WallpaperRevealMonitor.isDesktopBackground(windowOwner: finder, hitOwner: finder, role: kAXGroupRole))
        for role in [kAXImageRole, kAXButtonRole, kAXStaticTextRole, kAXMenuItemRole, "AXDockItem", "AXUnknown"] {
            #expect(!WallpaperRevealMonitor.isDesktopBackground(windowOwner: finder, hitOwner: finder, role: role))
        }
        for app in ["com.holdsnow.nearpane.alpha", "net.example.fixture", "com.apple.notificationcenterui"] {
            #expect(!WallpaperRevealMonitor.isDesktopBackground(windowOwner: finder, hitOwner: app, role: kAXWindowRole))
            #expect(!WallpaperRevealMonitor.isDesktopBackground(windowOwner: app, hitOwner: finder, role: kAXListRole))
        }
    }
}
