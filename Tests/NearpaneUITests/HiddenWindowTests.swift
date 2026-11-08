import AppKit
import Foundation
import Testing
import NearpaneCore
@testable import NearpaneUI

/// These tests never run NSApplication.run, orderFront, showWindow, makeKey or activate.
@MainActor
@Suite(.serialized)
struct HiddenWindowTests {
    @Test func noUsableDisplayOrRestoredHideNeverOrdersFront() async {
        _ = NSApplication.shared
        let store = MemoryConfigurationStore()
        let host = HostSession(store: store)
        await host.start()
        let controller = EdgeWindowController(host: host)
        let screen = ScreenGeometry(id: "menu", frame: .init(width: 1600, height: 900),
                                    visibleFrame: .init(y: 30, width: 1600, height: 870))
        let removed = ScreenGeometry(id: "gone", frame: screen.frame, visibleFrame: .init(width: 0, height: 0))
        controller.place(screens: [removed])
        #expect(!controller.hasPlacement)
        controller.presentIfNeeded()
        #expect(controller.window?.isVisible == false)
        host.setSurfaceHidden(true)
        host.stop()
        await host.start()
        #expect(host.configuration.surfaceHidden)
        controller.place(screens: [removed, screen])
        #expect(controller.hasPlacement)
        controller.presentIfNeeded()
        #expect(controller.window?.frame.width == 200)
        #expect(controller.window?.isVisible == false)
        controller.close()
        host.stop()
    }
    @Test func testNativePanelConstructsHiddenWithNoTitlebarAndNonactivatingPolicy() async {
        _ = NSApplication.shared
        let host = HostSession(store: MemoryConfigurationStore())
        let controller = EdgeWindowController(host: host)
        let panel = controller.window as? EdgePanel
        #expect(panel != nil)
        #expect(!(panel!.isVisible))
        #expect(panel!.title == "")
        #expect(!(panel!.styleMask.contains(.titled)))
        #expect(panel!.styleMask.contains(.nonactivatingPanel))
        #expect(panel!.becomesKeyOnlyIfNeeded)
        #expect(!(panel!.hidesOnDeactivate))
        #expect(panel!.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel!.level == .floating)
        #expect(panel!.contentView is NSVisualEffectView)
        controller.close()
    }

    @Test func testPlacementAndDisplayRemovalDoNotPresentWindowOrErasePreference() async {
        _ = NSApplication.shared
        let host = HostSession(store: MemoryConfigurationStore())
        await host.start()
        host.setPlacement(edge: .right, displayID: "portrait")
        let controller = EdgeWindowController(host: host)
        let main = ScreenGeometry(id: "main", frame: .init(width: 1440, height: 900), visibleFrame: .init(y: 40, width: 1440, height: 830))
        let portrait = ScreenGeometry(id: "portrait", frame: .init(x: -1080, width: 1080, height: 1920),
                                      visibleFrame: .init(x: -1080, y: 30, width: 1080, height: 1890))
        controller.place(screens: [main, portrait])
        #expect(controller.window!.frame.width == 135)
        #expect(controller.window!.frame.minX == -135)
        controller.place(screens: [main])
        #expect(controller.window!.frame.width == 180)
        #expect(host.configuration.preferredDisplayID == "portrait")
        #expect(!(controller.window!.isVisible))
        controller.place(screens: [])
        #expect(!(controller.window!.isVisible))
        controller.close()
        host.stop()
    }
}
