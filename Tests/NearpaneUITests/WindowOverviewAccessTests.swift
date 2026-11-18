import Testing
@testable import NearpaneUI

@MainActor struct WindowOverviewAccessTests {
    @Test func authorizationWhileSettingsIsOpenRemovesBothGuidesWithoutPrompting() {
        var grants = Set<WindowOverviewAccess.Permission>()
        var effects = 0
        let access = WindowOverviewAccess(read: { grants }, request: { _ in effects += 1 }, open: { _ in effects += 1 })
        grants = [.focus, .thumbnails]
        access.refresh()
        #expect(access.action(for: .focus) == nil)
        #expect(access.action(for: .thumbnails) == nil)
        #expect(effects == 0)
        grants.remove(.focus)
        access.refresh()
        #expect(access.action(for: .focus) == .request)
        #expect(access.action(for: .thumbnails) == nil)
    }

    @Test func requestNeverAlsoOpensSettingsAndStaleButtonsRecheckCurrentProcess() {
        var grants = Set<WindowOverviewAccess.Permission>()
        var requests = [WindowOverviewAccess.Permission](), panes = [WindowOverviewAccess.Permission]()
        let access = WindowOverviewAccess(read: { grants }, request: { requests.append($0) }, open: { panes.append($0) })
        access.perform(.request, for: .thumbnails)
        access.perform(.request, for: .thumbnails)
        #expect(requests == [.thumbnails] && panes.isEmpty)
        #expect(access.action(for: .focus) == .request)
        access.perform(.settings, for: .thumbnails)
        #expect(panes == [.thumbnails])
        grants = [.focus, .thumbnails]
        access.perform(.settings, for: .thumbnails)
        access.perform(.request, for: .focus)
        #expect(requests == [.thumbnails] && panes == [.thumbnails])
    }

    @Test func privateOrHiddenSessionAndDisabledPicturesDoNotOfferFalseScreenRecordingGuide() {
        #expect(WindowOverviewAccess.sidebarGuides(grants: [.thumbnails], showPictures: true, readerDenied: false, visible: true).isEmpty)
        #expect(WindowOverviewAccess.sidebarGuides(grants: [.thumbnails], showPictures: true, readerDenied: true, visible: true) == [.focus])
        #expect(WindowOverviewAccess.sidebarGuides(grants: [.focus, .thumbnails], showPictures: true, readerDenied: true, visible: true).isEmpty)
        #expect(WindowOverviewAccess.sidebarGuides(grants: [], showPictures: true, readerDenied: true, visible: false).isEmpty)
        #expect(WindowOverviewAccess.sidebarGuides(grants: [.focus], showPictures: false, readerDenied: true, visible: true).isEmpty)
        #expect(WindowOverviewAccess.sidebarGuides(grants: [.focus], showPictures: true, readerDenied: true, visible: true) == [.thumbnails])
    }
}
