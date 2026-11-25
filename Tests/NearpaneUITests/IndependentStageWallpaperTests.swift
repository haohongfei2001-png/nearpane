import AppKit
import NearpaneCore
import Testing
@testable import NearpaneUI

@MainActor struct IndependentStageWallpaperTests {
    @Test func wallpaperWaitsForANewOrdinaryReadWithoutHandingBackHiddenGroups() {
        let host = HostSession(store: MemoryConfigurationStore()), lane = NativeSidebarNavigation()
        let window = EdgeWindowController(host: host)
        let panels = DisplayPanels(host: host, primary: window, navigation: lane, present: { _ in })
        defer { panels.stop(); window.close() }
        panels.setWallpaperHeld(true)
        #expect(!lane.dispatchAvailable && panels.stageDisposition == .wallpaper)
        panels.setMissionControl(.unknown)
        #expect(panels.stageDisposition == .wallpaper)
        panels.setWallpaperHeld(false)
        #expect(!lane.dispatchAvailable && panels.stageDisposition == .wallpaper)
        panels.setMissionControl(.ordinary)
        #expect(lane.dispatchAvailable && panels.stageDisposition == .ordinary)
        panels.setMissionControl(.unknown)
        #expect(!lane.dispatchAvailable && panels.stageDisposition == .system)
    }

    @Test func realSystemTakeoverOverridesWallpaperEvenWhenDispatchWasAlreadyDisabled() {
        let host = HostSession(store: MemoryConfigurationStore()), lane = NativeSidebarNavigation()
        let window = EdgeWindowController(host: host)
        let panels = DisplayPanels(host: host, primary: window, navigation: lane, present: { _ in })
        defer { panels.stop(); window.close() }
        panels.setWallpaperHeld(true)
        panels.setMissionControl(.exposed)
        #expect(!lane.dispatchAvailable && panels.stageDisposition == .system)
        panels.setMissionControl(.ordinary)
        #expect(lane.dispatchAvailable && panels.stageDisposition == .ordinary)
        panels.setWallpaperHeld(true)
        panels.setSuspended(true)
        #expect(panels.stageDisposition == .system)
        panels.setSuspended(false)
        #expect(panels.stageDisposition == .ordinary)
        panels.setWallpaperHeld(true)
        panels.nativeDesktopChanged()
        #expect(!lane.dispatchAvailable && panels.stageDisposition == .system)
        panels.setMissionControl(.ordinary)
        #expect(lane.dispatchAvailable && panels.stageDisposition == .ordinary)
        panels.setWallpaperHeld(true)
        panels.setSystemManagesWindows(true)
        #expect(panels.stageDisposition == .system)
    }

    @Test func animatedInventoryInvalidationKeepsTheExplicitWallpaperPause() {
        let host = StageWindowEngineHost(profile: nil, store: StageGroupStore(profile: nil))
        host.setWallpaperHeld(true)
        host.freeze()
        #expect(host.wallpaperPaused)
        host.setWallpaperHeld(false)
        #expect(host.wallpaperPaused) // Ending the monitor alone is not physical readback.
        host.systemTakesOver()
        #expect(!host.wallpaperPaused)
    }
}
