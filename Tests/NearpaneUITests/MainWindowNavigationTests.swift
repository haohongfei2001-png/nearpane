import Testing
import NearpaneCore
@testable import NearpaneUI

@MainActor struct MainWindowNavigationTests {
    @Test func displayControlsHaveOneOwnerWithoutDroppingWorkingModuleOverrides() {
        let global = Set(DisplaySettingsScope.global.metrics)
        let voice = Set(DisplaySettingsScope.voice.metrics)
        let tray = Set(DisplaySettingsScope.tray.metrics)
        let spaces = Set(DisplaySettingsScope.spaces.metrics)
        #expect(global.isDisjoint(with: voice.union(tray).union(spaces)))
        #expect(voice.isDisjoint(with: tray.union(spaces)))
        #expect(tray.isDisjoint(with: spaces))
        #expect(voice.contains(.voiceHeight) && voice.contains(.textSize) && voice.contains(.copySize))
        #expect(tray.contains(.trayHeight) && tray.contains(.trayButtonSize))
        #expect(spaces.contains(.spacesHeight) && spaces.contains(.spaceRowHeight) && spaces.contains(.labelSize))
        #expect(global.contains(.cornerRadius) && global.contains(.sectionGap) && global.contains(.railHeight))
        let dedicatedOrInactive: Set<DisplayMetric> = [.panelWidth, .panelHeight, .scrollHeight]
        #expect(global.union(voice).union(tray).union(spaces).union(dedicatedOrInactive) == Set(DisplayMetric.allCases))
    }

    @Test func firstOpenExplainsCompositionAndSectionSwitchesKeepTheirPlace() {
        let navigation = SettingsNavigation()
        #expect(navigation.page == .modules)
        navigation.showScreenshotArchive()
        navigation.showAppearance()
        navigation.showModule(BuiltinCatalog.lyrics)
        navigation.select(.library)
        #expect(navigation.page == .screenshotArchive)
        navigation.select(.settings)
        #expect(navigation.page == .dimensions)
        navigation.select(.modules)
        #expect(navigation.page == .modules && navigation.moduleID == nil)
    }

    @Test func allSpacesEntriesShareTheModuleParent() {
        let navigation = SettingsNavigation()
        navigation.showWindowManagement()
        #expect(navigation.moduleID == BuiltinCatalog.desktop)
        #expect(navigation.section == .modules)
        navigation.showDesktop()
        #expect(navigation.moduleID == BuiltinCatalog.desktop)
        #expect(navigation.section == .modules)
        navigation.page = .windowRules
        #expect(navigation.moduleID == BuiltinCatalog.desktop)
        navigation.showModules()
        #expect(navigation.moduleID == nil)
    }

    @Test func lyricsDeepLinksKeepTheSameModuleAndInvalidPagesFallBackToSettings() {
        let navigation = SettingsNavigation()
        for page in ["fullLyrics", "source", "adjustment", "candidates"] {
            navigation.showLyrics(page)
            #expect(navigation.moduleID == BuiltinCatalog.lyrics)
            #expect(navigation.lyricsPage == page)
            #expect(navigation.section == .modules)
        }
        navigation.showLyrics("not-a-page")
        #expect(navigation.lyricsPage == "settings")
        navigation.showModule(BuiltinCatalog.lyrics)
        #expect(navigation.lyricsPage == "settings")
    }

    @Test func contentDestinationsRemainIndependentOfModuleDetailSelection() {
        let navigation = SettingsNavigation()
        navigation.showNotebookLibrary("tasks")
        navigation.showModule(BuiltinCatalog.memo)
        #expect(navigation.moduleID == BuiltinCatalog.memo)
        navigation.showLibrary()
        #expect(navigation.page == .tasksArchive && navigation.moduleID == nil)
        navigation.showNotebookLibrary("vocabulary")
        #expect(navigation.section == .library)
        navigation.showGeneral()
        navigation.showLibrary()
        #expect(navigation.page == .wordArchive)
    }
}
