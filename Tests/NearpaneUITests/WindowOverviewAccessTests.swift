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

    @Test func accessGuideUsesTheStableAppForRequestsAndRecognizesEitherActualPrincipal() async {
        var hostGrants: Set<WindowOverviewAccess.Permission> = [.focus, .thumbnails]
        var helper: Bool? = false
        var hostRequests = [WindowOverviewAccess.Permission]()
        var workerCalls = [Bool]()
        var systemPanes = [WindowOverviewAccess.Permission]()
        let access = WindowOverviewAccess(read: { hostGrants }, request: { hostRequests.append($0) },
                                          open: { systemPanes.append($0) }, readWorker: { prompt in
            workerCalls.append(prompt); return helper
        })
        await access.checkGuide(force: true)
        #expect(access.guideAction(for: .thumbnails) == nil && access.guideAction(for: .focus) == nil)
        #expect(access.focusAvailable == true && access.workerFocus == false)
        hostGrants.remove(.focus)
        await access.checkGuide(force: true)
        #expect(access.guideAction(for: .focus) == .request)
        await access.performGuide(.request, for: .focus)
        await access.performGuide(.request, for: .focus)
        #expect(hostRequests == [.focus] && !workerCalls.contains(true))
        #expect(access.guideAction(for: .focus) == .settings && systemPanes.isEmpty)
        helper = true
        await access.performGuide(.settings, for: .focus)
        #expect(access.guideAction(for: .focus) == nil && systemPanes.isEmpty)
        await access.checkAfterRequest()
        #expect(access.observeUntil == 0)
        helper = nil
        await access.checkGuide(force: true)
        #expect(access.checkedWorker && access.workerFocus == nil && access.guideAction(for: .focus) == nil)
    }

    @Test func hostWindowBindingRequiresTheSelectedPublicNumberExactlyOnce() {
        #expect(HostCurrentWindowFocus.exactIndex(numbers: [44, 55], selected: 55) == 1)
        #expect(HostCurrentWindowFocus.exactIndex(numbers: [nil, 44], selected: 55) == nil)
        #expect(HostCurrentWindowFocus.exactIndex(numbers: [55, 55], selected: 55) == nil)
        #expect(HostCurrentWindowFocus.exactIndex(numbers: [0], selected: 0) == nil)
        #expect(HostCurrentWindowFocus.exactIndex(numbers: [55] + Array(repeating: nil, count: 64), selected: 55) == nil)
    }

    @Test func accessGrantedOutsideTheAppUpdatesGuideWithoutRequestOrWindowAccess() async {
        var screen = false
        var prompts = [WindowOverviewAccess.Permission]()
        var workerPrompts = [Bool]()
        let access = WindowOverviewAccess(read: { screen ? [.thumbnails] : [] }, request: { prompts.append($0) },
                                          open: { _ in Issue.record("unexpected settings redirect") }, readWorker: { ask in
            workerPrompts.append(ask); return true
        })
        await access.checkGuide()
        #expect(access.guideAction(for: .thumbnails) == .request && access.guideAction(for: .focus) == nil)
        await access.performGuide(.request, for: .thumbnails)
        #expect(access.observeUntil > 0 && prompts == [.thumbnails])
        screen = true
        let before = workerPrompts.count
        await access.checkAfterRequest()
        #expect(access.observeUntil == 0 && access.guideAction(for: .thumbnails) == nil)
        #expect(workerPrompts.count == before && !workerPrompts.contains(true))
    }
}
