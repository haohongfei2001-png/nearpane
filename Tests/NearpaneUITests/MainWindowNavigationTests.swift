import Foundation
import Testing
import NearpaneCore
@testable import NearpaneUI

@MainActor struct MainWindowNavigationTests {
    @Test func visualControlsHaveOneOwnerAndExposeOnlyWidthAndBoundedTypography() {
        let global = Set(DisplaySettingsScope.global.metrics)
        let voice = Set(DisplaySettingsScope.voice.metrics)
        let tray = Set(DisplaySettingsScope.tray.metrics)
        let spaces = Set(DisplaySettingsScope.spaces.metrics)
        #expect(global.isDisjoint(with: voice.union(tray).union(spaces)))
        #expect(voice.isDisjoint(with: tray.union(spaces)))
        #expect(tray.isDisjoint(with: spaces))
        #expect(global == [.panelWidth])
        #expect(voice == [.textSize])
        #expect(spaces == [.labelSize])
        #expect(tray.isEmpty)
        #expect(global.union(voice).union(spaces) == [.panelWidth, .textSize, .labelSize])
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
        #expect(navigation.page == .memoArchive && navigation.moduleID == nil)
        #expect(navigation.notebookFilter == "unfinished")
        navigation.showNotebookLibrary("vocabulary")
        #expect(navigation.section == .library)
        navigation.showGeneral()
        navigation.showLibrary()
        #expect(navigation.page == .wordArchive)
    }

    @Test func noteAndTaskFiltersShareOneRepositoryRoute() {
        let navigation = SettingsNavigation()
        for (alias, filter) in [("all", "all"), ("notes", "notes"), ("tasks", "unfinished"),
                                ("pending", "unfinished"), ("unfinished", "unfinished"), ("completed", "completed")] {
            navigation.showNotebookLibrary(alias)
            #expect(navigation.page == .memoArchive)
            #expect(navigation.notebookFilter == filter)
            #expect(navigation.selectedNotebookRecordID == nil)
        }
        navigation.showModule(BuiltinCatalog.tasks)
        #expect(navigation.moduleID == BuiltinCatalog.memo)
    }

    @Test func sidebarRecordDeepLinkSurvivesSectionSwitchesWithoutASecondWindowRoute() {
        let navigation = SettingsNavigation()
        let id = UUID()
        navigation.showNotebookLibrary("record:" + id.uuidString)
        #expect(navigation.page == .memoArchive)
        #expect(navigation.selectedNotebookRecordID == id)
        #expect(navigation.notebookFilter == "all")
        navigation.showModules()
        navigation.showLibrary()
        #expect(navigation.page == .memoArchive && navigation.selectedNotebookRecordID == id)
        navigation.showNotebookLibrary("completed", recordID: id)
        #expect(navigation.notebookFilter == "all")
        navigation.showNotebookLibrary("record:invalid")
        #expect(navigation.selectedNotebookRecordID == nil)
        #expect(navigation.notebookFilter == "all")
        navigation.showNotebookRecord(id)
        #expect(navigation.selectedNotebookRecordID == id)
        let revision = navigation.notebookNavigationRevision
        navigation.showNotebookRecord(id)
        #expect(navigation.notebookNavigationRevision == revision + 1)
    }
}
