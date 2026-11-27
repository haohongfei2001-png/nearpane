import Testing
import NearpaneCore
@testable import NearpaneUI

@MainActor struct MainWindowNavigationTests {
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
