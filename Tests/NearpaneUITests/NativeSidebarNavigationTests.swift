import AppKit
import Foundation
import NearpaneCore
@testable import NearpaneUI
import Testing

@MainActor private final class SidebarActivityRecorder {
    private(set) var begun = [Int](), ended = [Int]()
    let completions = AsyncStream<Int>.makeStream()

    func begin() -> NativeSidebarNavigation.ActivityCompletion {
        let id = begun.count + 1
        begun.append(id)
        return {
            self.ended.append(id)
            self.completions.continuation.yield(id)
        }
    }
}

@MainActor struct NativeSidebarNavigationTests {
    @Test func externalActivationRetiresOnlyThePendingCrossSpaceFocus() {
        let source = SelectionForeground(pid: 100, birth: 10)
        let target = SelectionForeground(pid: 200, birth: 20)
        for superseding in [nil, source, SelectionForeground(pid: 200, birth: 21), SelectionForeground(pid: 300, birth: 30)] {
            var continuity = CrossSpaceFocusContinuity(source: source, target: target)
            let sequence = [source, target, superseding, target].map { continuity.observe($0) }
            #expect(sequence == [true, true, false, false])
        }
        var related = CrossSpaceFocusContinuity(source: target, target: target)
        let sameApp = [target, target].map { related.observe($0) }
        #expect(sameApp == [true, true])
    }
    let a = UUID(), b = UUID(), c = UUID(), session = UUID()
    let frame = SurfaceRect(x: 10, y: 20, width: 300, height: 200)

    func window(_ number: UInt32, _ spaces: [String], front: Int, birth: UInt64 = 9,
                role: Bool? = true, minimized: Bool = false) -> WindowObservation {
        .init(id: "w" + String(number), displayID: "screen", bounds: frame,
              membership: spaces.isEmpty ? .unknown : .known(recordIDs: spaces), confidence: .unknown,
              metadata: .init(number: number, pid: 54, launchMicroseconds: birth, element: nil, globalFrame: frame,
                frontToBack: front, minimized: minimized, fullScreen: nil, isOnscreen: spaces.contains("1"),
                onActiveDesktop: spaces.contains("1"), overviewSpaceID: spaces.contains("1") ? "1" : nil, overviewOrdinaryRole: role))
    }

    func snapshot(_ windows: [WindowObservation], complete: Bool = true, rev: UInt64 = 1,
                  backgroundID: UUID? = nil, topology: String = "screens", fullscreenID: UUID? = nil) -> DesktopSnapshot {
        let size = SurfaceRect(width: 800, height: 600), now = Date(), uptime = ProcessInfo.processInfo.systemUptime
        return .observed(.init(session: session, revision: rev, parentPID: 1, fixtureWindows: nil,
                               anchors: [], experimentalSpaces: false), from: now, to: now, build: "fixture",
                topology: topology, consistent: true, separateSpaces: true,
                displays: [.init(id: "screen", frame: size, rotationDegrees: 0, backingScale: 1, usable: size)],
                scopes: [.init(id: "scope", displayID: "screen", records: [
                    .init(id: "1", isCurrent: true, ordinaryUUID: a), .init(id: "2", isCurrent: false, ordinaryUUID: backgroundID ?? b),
                    .init(id: "3", isCurrent: false, ordinaryUUID: c), .init(id: "7", isCurrent: false, fullscreenUUID: fullscreenID)
                ])], windows: windows, evidence: .init(population: .workWindows, accessibility: .available,
                        spaces: .observed, rows: [], windowLimitReached: false, beganUptime: uptime, endedUptime: uptime,
                        catalogComplete: complete))
    }

    func map(_ s: DesktopSnapshot) throws -> NativeSpaceCatalog {
        try #require(NativeSpaceCatalog(s, displayID: "screen", now: .now, uptime: ProcessInfo.processInfo.systemUptime))
    }

    @Test func ordinaryCardPointerDistinguishesClickDropAndCancelledTargetsWithoutOrderingAWindow() throws {
        let panel = EdgePanel(contentRect: .init(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let content = try #require(panel.contentView)
        let first = window(8, ["1"], front: 0), second = window(9, ["1"], front: 1)
        let catalog = try map(snapshot([first, second]))
        let destination = try #require(NativeSidebarDestination(catalog.rows[0], in: catalog))
        let a = try #require(NativeSidebarMember(first, source: destination))
        let b = try #require(NativeSidebarMember(second, source: destination))
        var clicks = [UInt32](), placements = [SidebarPairDrop](), live = true
        for (i, member) in [a, b].enumerated() {
            let area = SidebarCardPointer.CardArea(frame: .init(x: 20, y: i * 85 + 10, width: 160, height: 70))
            area.card = SidebarCardPointer(member: member, lifetime: UUID(), current: { live },
                select: { clicks.append(member.key.number) }, place: { placements.append($0) }, highlight: { _ in })
            content.addSubview(area)
        }
        func route(_ type: NSEvent.EventType, _ x: Int, _ y: Int, _ flags: NSEvent.ModifierFlags = []) throws -> Bool {
            let event = try #require(NSEvent.mouseEvent(with: type, location: .init(x: x, y: y), modifierFlags: flags,
                timestamp: 1, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            return panel.cardPointer.receive(event, in: panel)
        }
        #expect(try !route(.leftMouseDown, 25, 25, .control))
        #expect(try route(.leftMouseDown, 25, 25) && route(.leftMouseUp, 26, 25))
        #expect(clicks == [8])
        for x in [32, 160] {
            #expect(try route(.leftMouseDown, 25, 25) && route(.leftMouseDragged, x, 120) && route(.leftMouseUp, x, 120))
        }
        #expect(placements.map(\.draggedOnLeft) == [true, false])
        #expect(placements.allSatisfy { $0.dragged == a && $0.target == b })
        #expect(try route(.leftMouseDown, 25, 25) && route(.leftMouseDragged, 120, 30) && route(.leftMouseUp, 120, 30))
        #expect(try route(.leftMouseDown, 25, 25))
        live = false
        #expect(try route(.leftMouseUp, 150, 120))
        #expect(clicks == [8] && placements.count == 2)
    }

    @Test func overlappingLiveMembersDragAndSelectOnlyTheFrontWindowInOneGroupSnapshot() throws {
        let panel = EdgePanel(contentRect: .init(x:0,y:0,width:220,height:200),
                              styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:true)
        let content = try #require(panel.contentView)
        let windows = [window(8,["1"],front:1), window(9,["1"],front:0), window(10,["1"],front:2)]
        let sample = snapshot(windows), group = UUID()
        let catalog = try map(sample)
        let home = try #require(NativeSidebarDestination(catalog.rows[0],in:catalog))
        var clicked = [UInt32](), drops = [SidebarPairDrop](), stale = Set<UInt32>()
        var areas = [SidebarCardPointer.CardArea]()
        let frames = [NSRect(x:10,y:10,width:120,height:60), NSRect(x:55,y:10,width:120,height:60),
                      NSRect(x:10,y:100,width:165,height:55)]
        func stack(_ rank: Int, revision: UInt64? = nil) -> SidebarCardPointer.StackPosition {
            .init(group:group,session:sample.sessionID,revision:revision ?? sample.revision,frontToBack:rank)
        }
        for (index, w) in windows.enumerated() {
            let member = try #require(NativeSidebarMember(w,source:home))
            let area = SidebarCardPointer.CardArea(frame:frames[index])
            area.card = .init(member:member,lifetime:UUID(),current:{ !stale.contains(member.key.number) },
                              select:{ clicked.append(member.key.number) },place:{ drops.append($0) },highlight:{ _ in },
                              stack:index < 2 ? stack(index == 0 ? 1 : 0) : nil)
            content.addSubview(area)
            areas.append(area)
        }
        func point(_ type: NSEvent.EventType, _ x: Int, _ y: Int) throws {
            let e = try #require(NSEvent.mouseEvent(with:type,location:.init(x:x,y:y),modifierFlags:[],timestamp:1,
                windowNumber:panel.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1))
            #expect(panel.cardPointer.receive(e,in:panel))
        }
        try point(.leftMouseDown,35,35); try point(.leftMouseUp,35,35)
        try point(.leftMouseDown,70,35); try point(.leftMouseUp,70,35)
        try point(.leftMouseDown,70,35); try point(.leftMouseDragged,40,120); try point(.leftMouseUp,40,120)
        try point(.leftMouseDown,40,120); try point(.leftMouseDragged,70,35); try point(.leftMouseUp,70,35)
        #expect(clicked == [8,9])
        #expect(drops.map { $0.dragged.key.number } == [9,10])
        #expect(drops.map { $0.target.key.number } == [10,9])
        #expect(drops.map { $0.draggedOnLeft } == [true,true])

        stale.insert(9)
        try point(.leftMouseDown,70,35); try point(.leftMouseUp,70,35)
        stale.remove(9)
        areas[0].card?.stack = stack(0)
        try point(.leftMouseDown,70,35); try point(.leftMouseUp,70,35)
        areas[0].card?.stack = stack(1,revision:sample.revision + 1)
        try point(.leftMouseDown,70,35); try point(.leftMouseUp,70,35)
        areas[0].card?.stack = stack(1)
        try point(.leftMouseDown,70,35)
        areas[1].card?.stack = stack(2)
        try point(.leftMouseUp,70,35)
        try point(.leftMouseDown,35,35); try point(.leftMouseDragged,40,120)
        stale.insert(8)
        try point(.leftMouseUp,40,120)
        #expect(clicked == [8,9] && drops.count == 2)
    }

    @Test(.enabled("AppKit must expose the screen containing the panel") { await MainActor.run { !NSScreen.screens.isEmpty } })
    func draggingALiveMemberOutDetachesOnlyOnReleaseInTheSameWorkspace() throws {
        let screen = try #require(NSScreen.screens.first)
        let device = try #require(screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber)
        let uuid = try #require(CGDisplayCreateUUIDFromDisplayID(device.uint32Value)?.takeRetainedValue())
        let displayID = CFUUIDCreateString(nil,uuid) as String
        let work = screen.visibleFrame
        let panel = EdgePanel(contentRect:.init(x:work.midX-100,y:work.midY-40,width:100,height:80),
                              styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:true)
        let area = SidebarCardPointer.CardArea(frame:.init(x:0,y:0,width:100,height:80))
        try #require(panel.contentView).addSubview(area)
        let w = window(12,["1"],front:0)
        let location = NativeSidebarDestination(session:session,topology:"display-test",display:displayID,space:"1",uuid:a)
        let fixture = WindowObservation(id:w.id,displayID:displayID,bounds:w.bounds,membership:w.membership,
                                        confidence:w.confidence,metadata:w.metadata)
        let member = try #require(NativeSidebarMember(fixture,source:location))
        var removed = 0, live = true
        area.card = .init(member:member,lifetime:UUID(),current:{ live },select:{},place:{ _ in },highlight:{ _ in },
                          stack:.init(group:b,session:session,revision:1,frontToBack:0),detach:{ removed += 1 })
        func route(_ type: NSEvent.EventType, x: CGFloat, flags: NSEvent.ModifierFlags = []) throws {
            let event = try #require(NSEvent.mouseEvent(with:type,location:.init(x:x,y:25),modifierFlags:flags,
                timestamp:1,windowNumber:panel.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1))
            #expect(panel.cardPointer.receive(event,in:panel))
        }
        try route(.leftMouseDown,x:20); try route(.leftMouseUp,x:160)
        try route(.leftMouseDown,x:20); try route(.leftMouseDragged,x:109); try route(.leftMouseUp,x:109)
        try route(.leftMouseDown,x:20); try route(.leftMouseDragged,x:145); try route(.leftMouseUp,x:160,flags:.shift)
        try route(.leftMouseDown,x:20); try route(.leftMouseDragged,x:145)
        live = false
        try route(.leftMouseUp,x:160)
        live = true
        try route(.leftMouseDown,x:20); try route(.leftMouseDragged,x:145); try route(.leftMouseUp,x:work.width+150)
        #expect(removed == 0)
        try route(.leftMouseDown,x:20); try route(.leftMouseDragged,x:145); try route(.leftMouseUp,x:160)
        #expect(removed == 1)
    }

    @Test func internalCatalogKeepsNeverVisitedAndEmptySpacesForDispatch() throws {
        let all = snapshot([window(8, ["1"], front: 2), window(9, ["2"], front: 1), window(7, ["1","2"], front: 0)])
        let rows = try map(all).rows
        #expect(rows.map(\.id) == ["1","2","3"])
        #expect(rows.map { $0.windows.map(\.id) } == [["w7","w8"],["w7","w9"],[]])
        #expect(rows[2].regularWindowListComplete)
        #expect(all.currentDesktopWindows(on: "screen", now: .now, uptime: ProcessInfo.processInfo.systemUptime).map(\.id) == ["w7","w8"])
        #expect(try !map(snapshot([], complete: false)).rows[2].regularWindowListComplete)
        #expect(try !map(snapshot([window(9, [], front: 0)])).rows[2].regularWindowListComplete)
    }

    @Test func emptyOrdinaryFullscreenAndUnreadSpacesProduceNoSidebarEntries() throws {
        for complete in [true, false] {
            let catalog = try map(snapshot([], complete: complete, fullscreenID: UUID()))
            #expect(catalog.rows.count == 4)
            #expect(SidebarBackgroundWindows.sections(in: catalog).isEmpty)
        }
    }

    @Test func onlyConfirmedWindowsAppearOnceAndDisappearWhenTheyClose() throws {
        let sharedWithCurrent = window(8, ["1","2"], front: 0)
        let sharedInBackground = window(9, ["2","3"], front: 1)
        let fullscreenDocument = window(10, ["7"], front: 2)
        let uncertain = window(11, [], front: 3)
        let panel = window(12, ["2"], front: 4, role: false)
        let unclassified = window(13, ["2"], front: 5, role: nil)
        let minimized = window(14, ["3"], front: 6, minimized: true)
        let noOwnerBirth = window(15, ["3"], front: 7, birth: 0)
        let others = [sharedWithCurrent, uncertain, panel, unclassified, minimized, noOwnerBirth]
        let fullscreenID = UUID()
        let visible = try map(snapshot(others + [sharedInBackground, fullscreenDocument], complete: false, fullscreenID: fullscreenID))
        let sections = SidebarBackgroundWindows.sections(in: visible)
        #expect(sections.map { $0.windows.map(\.id) } == [["w9"], ["w10"]])
        #expect(sections.map(\.destination.kind) == [.ordinary, .fullscreen])
        let afterClosing = try map(snapshot(others, fullscreenID: fullscreenID))
        #expect(SidebarBackgroundWindows.sections(in: afterClosing).isEmpty)
    }

    @Test func gestureSurvivesUnrelatedRefreshButNotReplacedOwnerSpaceOrTopology() throws {
        let w = window(8, ["2"], front: 0), initial = try map(snapshot([w]))
        let dest = try #require(NativeSidebarDestination(initial.rows[1], in: initial))
        let member = try #require(NativeSidebarMember(w, source: dest))
        #expect(member.resolve(snapshot([w, window(7, ["1"], front: 1)], rev: 5)) != nil)
        #expect(member.resolve(snapshot([window(8, ["2"], front: 0, birth: 33)])) == nil)
        #expect(member.resolve(snapshot([w], backgroundID: UUID())) == nil)
        #expect(member.resolve(snapshot([w], topology: "reconnected")) == nil)
        #expect(member.resolve(snapshot([window(8, ["1"], front: 0)])) == nil)
    }

    @Test func groupNameReadCannotCommitAcrossASidebarIntentOrOwnershipLoss() async throws {
        let router = NativeSidebarNavigation()
        let editing = try #require(router.idleGeneration)
        var completed = false
        router.submit(stage: true) { _ in completed = true }
        #expect(router.idleGeneration == nil)
        while !completed { await Task.yield() }
        #expect(router.idleGeneration != nil && router.idleGeneration != editing)
        let idle = router.idleGeneration
        router.setDispatchAvailable(false)
        #expect(router.idleGeneration == nil)
        router.setDispatchAvailable(true)
        #expect(router.idleGeneration != nil && router.idleGeneration != idle)
    }

    @Test(.timeLimit(.minutes(1))) func utilitySubmissionKeepsUserActionPriorityAcrossSuspension() async throws {
        let lane = NativeSidebarNavigation()
        let submitted = AsyncStream<TaskPriority>.makeStream()
        let started = AsyncStream<TaskPriority>.makeStream()
        let resume = AsyncStream<Void>.makeStream()
        let finished = AsyncStream<TaskPriority>.makeStream()
        defer {
            submitted.continuation.finish(); started.continuation.finish()
            resume.continuation.finish(); finished.continuation.finish()
        }
        let submitter = Task.detached(priority: .utility) {
            await MainActor.run {
                let sourcePriority = Task.currentPriority
                lane.submit(stage: true) { _ in
                    started.continuation.yield(Task.currentPriority)
                    var release = resume.stream.makeAsyncIterator()
                    _ = await release.next()
                    finished.continuation.yield(Task.currentPriority)
                }
                submitted.continuation.yield(sourcePriority)
            }
        }
        // Await streams, not submitter.value: a high-priority waiter would
        // otherwise elevate the utility parent and mask the inheritance bug.
        var origin = submitted.stream.makeAsyncIterator()
        var entry = started.stream.makeAsyncIterator()
        var completion = finished.stream.makeAsyncIterator()
        let sourcePriority = try #require(await origin.next())
        let enteredPriority = try #require(await entry.next())
        #expect(sourcePriority == .utility && enteredPriority == .userInitiated)
        #expect(lane.isDispatching)
        resume.continuation.yield(())
        let resumedPriority = try #require(await completion.next())
        #expect(resumedPriority == .userInitiated)
        await submitter.value
    }

    @Test(.timeLimit(.minutes(1))) func userActivityBeginsBeforePreparationAndEndsAfterWorkReturns() async throws {
        let activities = SidebarActivityRecorder()
        let lane = NativeSidebarNavigation(beginUserActivity: { activities.begin() })
        let started = AsyncStream<Void>.makeStream(), resume = AsyncStream<Void>.makeStream()
        defer {
            started.continuation.finish(); resume.continuation.finish()
            activities.completions.continuation.finish()
        }
        var prepared = false
        lane.submit(stage: true, prepare: {
            #expect(activities.begun == [1] && activities.ended.isEmpty)
            prepared = true
        }) { _ in
            #expect(prepared && activities.ended.isEmpty)
            started.continuation.yield(())
            var release = resume.stream.makeAsyncIterator()
            _ = await release.next()
            #expect(activities.ended.isEmpty)
        }
        #expect(prepared && activities.begun == [1] && activities.ended.isEmpty)
        var entered = started.stream.makeAsyncIterator()
        _ = await entered.next()
        #expect(lane.isDispatching && activities.ended.isEmpty)
        resume.continuation.yield(())
        var completed = activities.completions.stream.makeAsyncIterator()
        let ended = try #require(await completed.next())
        #expect(ended == 1 && activities.ended == [1] && !lane.isDispatching)
    }

    @Test(.timeLimit(.minutes(1))) func replacedAndClearedActivitiesEndWithoutEndingRunningWork() async throws {
        let activities = SidebarActivityRecorder()
        let lane = NativeSidebarNavigation(beginUserActivity: { activities.begin() })
        let started = AsyncStream<UUID>.makeStream(), resume = AsyncStream<Void>.makeStream()
        defer {
            started.continuation.finish(); resume.continuation.finish()
            activities.completions.continuation.finish()
        }
        var effects = [String]()
        lane.submit(selection: false, stage: true) { token in
            started.continuation.yield(token)
            var release = resume.stream.makeAsyncIterator()
            _ = await release.next()
            #expect(!lane.isCurrent(token) && !activities.ended.contains(1))
        }
        var entered = started.stream.makeAsyncIterator()
        let original = try #require(await entered.next())
        lane.submit(stage: true) { _ in effects.append("replaced") }
        lane.submit(stage: true) { _ in effects.append("cleared") }
        #expect(!lane.isCurrent(original))
        #expect(activities.begun == [1, 2, 3] && activities.ended == [2])
        lane.setDispatchAvailable(false)
        #expect(activities.ended == [2, 3] && lane.isDispatching)
        resume.continuation.yield(())
        var completed = activities.completions.stream.makeAsyncIterator()
        for expected in [2, 3, 1] {
            let ended = try #require(await completed.next())
            #expect(ended == expected)
        }
        #expect(effects.isEmpty && activities.ended == [2, 3, 1] && !lane.isDispatching)
    }

    @Test(.timeLimit(.minutes(1))) func skippedUnconfirmedAndThrowingJobsEachEndTheirAcceptedActivity() async throws {
        let activities = SidebarActivityRecorder()
        let lane = NativeSidebarNavigation(beginUserActivity: { activities.begin() })
        let started = AsyncStream<Void>.makeStream(), resume = AsyncStream<Void>.makeStream()
        defer {
            started.continuation.finish(); resume.continuation.finish()
            activities.completions.continuation.finish()
        }
        var ownsDispatch = false, confirmations = 0, effects = [String]()
        lane.stageOwnsWindowDispatch = { ownsDispatch }
        lane.submit(selection: false, stage: true) { _ in
            started.continuation.yield(())
            var release = resume.stream.makeAsyncIterator()
            _ = await release.next()
        }
        var entered = started.stream.makeAsyncIterator()
        _ = await entered.next()
        lane.submit(selection: false) { _ in effects.append("skipped ordinary job") }
        ownsDispatch = true
        lane.confirmDispatch = {
            confirmations += 1
            return confirmations > 1
        }
        lane.submit(selection: false, stage: true) { _ in effects.append("unconfirmed job") }
        lane.submit(selection: false, stage: true) { _ in
            effects.append("throwing job")
            throw UnconfirmedSpaceMove("fixture failure")
        }
        #expect(activities.begun == [1, 2, 3, 4] && activities.ended.isEmpty)
        resume.continuation.yield(())
        var completed = activities.completions.stream.makeAsyncIterator()
        for expected in 1...4 {
            let ended = try #require(await completed.next())
            #expect(ended == expected)
        }
        #expect(effects == ["throwing job"] && confirmations == 2)
        #expect(activities.ended == [1, 2, 3, 4] && !lane.isDispatching)
    }

    @Test(.timeLimit(.minutes(1))) func rejectedAndAutomaticJobsDoNotBeginUserActivities() async {
        let activities = SidebarActivityRecorder()
        let lane = NativeSidebarNavigation(beginUserActivity: { activities.begin() })
        let started = AsyncStream<Void>.makeStream(), resume = AsyncStream<Void>.makeStream()
        let returned = AsyncStream<Void>.makeStream()
        defer {
            started.continuation.finish(); resume.continuation.finish(); returned.continuation.finish()
            activities.completions.continuation.finish()
        }
        var effects = [String](), ownsDispatch = true
        lane.setDispatchAvailable(false)
        lane.submit(stage: true) { _ in effects.append("unavailable") }
        lane.setDispatchAvailable(true)
        lane.stageOwnsWindowDispatch = { ownsDispatch }
        lane.submit { _ in effects.append("owned by stage") }
        #expect(activities.begun.isEmpty)
        ownsDispatch = false
        lane.submit(selection: false, stage: true, userActivity: false) { _ in
            #expect(lane.retainRunningUserActivity() == nil)
            started.continuation.yield(())
            var release = resume.stream.makeAsyncIterator()
            _ = await release.next()
            returned.continuation.yield(())
        }
        var entered = started.stream.makeAsyncIterator()
        _ = await entered.next()
        #expect(activities.begun.isEmpty && lane.isDispatching)
        for _ in 0..<8 {
            lane.submit(selection: false, stage: true) { _ in effects.append("cleared pending") }
        }
        lane.submit(selection: false, stage: true) { _ in effects.append("overflow") }
        #expect(activities.begun == Array(1...8) && activities.ended.isEmpty)
        lane.setDispatchAvailable(false)
        #expect(activities.ended == Array(1...8))
        resume.continuation.yield(())
        var finished = returned.stream.makeAsyncIterator()
        _ = await finished.next()
        #expect(effects.isEmpty && !lane.isDispatching)
        #expect(activities.begun == activities.ended)
    }

    @Test(.timeLimit(.minutes(1))) func observerCompletionHoldsOutliveOnlyTheirRunningUserJob() async throws {
        let activities = SidebarActivityRecorder()
        let lane = NativeSidebarNavigation(beginUserActivity: { activities.begin() })
        let started = AsyncStream<Void>.makeStream(), resume = AsyncStream<Void>.makeStream()
        let returned = AsyncStream<Void>.makeStream()
        defer {
            started.continuation.finish(); resume.continuation.finish(); returned.continuation.finish()
            activities.completions.continuation.finish()
        }
        #expect(lane.retainRunningUserActivity() == nil)
        lane.submit(stage: true) { _ in
            started.continuation.yield(())
            var release = resume.stream.makeAsyncIterator()
            _ = await release.next()
            returned.continuation.yield(())
        }
        var entered = started.stream.makeAsyncIterator()
        _ = await entered.next()
        // This test task is separate from the lane's executing task, just as an
        // ownership observer can independently start the engine's release tail.
        let firstCompletion = try #require(lane.retainRunningUserActivity())
        let lastCompletion = try #require(lane.retainRunningUserActivity())
        lane.setDispatchAvailable(false)
        firstCompletion(); firstCompletion()
        #expect(activities.ended.isEmpty)
        resume.continuation.yield(())
        var finished = returned.stream.makeAsyncIterator()
        _ = await finished.next()
        #expect(!lane.isDispatching && activities.ended.isEmpty)
        #expect(lane.retainRunningUserActivity() == nil)
        lane.setDispatchAvailable(true)
        lane.submit(stage: true) { _ in }
        var completed = activities.completions.stream.makeAsyncIterator()
        let newerJob = try #require(await completed.next())
        #expect(newerJob == 2 && activities.ended == [2])
        lastCompletion(); lastCompletion()
        #expect(activities.begun == [1, 2] && activities.ended == [2, 1])
    }

    @Test func thumbnailAdmissionWaitsForEveryQueuedWindowActionThenReadsPermissionAgain() async {
        let lane = NativeSidebarNavigation()
        var first: CheckedContinuation<Void, Never>?, second: CheckedContinuation<Void, Never>?
        lane.submit(selection: false, stage: true) { _ in await withCheckedContinuation { first = $0 } }
        #expect(lane.isDispatching) // The click owns the lane before its task starts.
        while first == nil { await Task.yield() }
        var waiting = false, permission = true, admissionReads = 0
        let refresh = Task {
            guard await DesktopWindowGallery.awaitDispatchTurn(navigation: lane, current: {
                waiting = true
                return true
            }) else { return false }
            admissionReads += 1
            return permission
        }
        while !waiting { await Task.yield() }
        #expect(admissionReads == 0)
        lane.submit(selection: false, stage: true) { _ in await withCheckedContinuation { second = $0 } }
        first?.resume()
        while second == nil { await Task.yield() }
        #expect(lane.isDispatching && admissionReads == 0)
        permission = false // A grant from before dispatch must not be replayed.
        second?.resume()
        #expect(await refresh.value == false)
        #expect(admissionReads == 1 && !lane.isDispatching)
    }

    @Test func thumbnailDispatchWaitCanBeCancelledWithoutWaitingForTheWindowAction() async {
        let lane = NativeSidebarNavigation()
        var finish: CheckedContinuation<Void, Never>?
        lane.submit(stage: true) { _ in await withCheckedContinuation { finish = $0 } }
        while finish == nil { await Task.yield() }
        var waiting = false
        let refresh = Task {
            await DesktopWindowGallery.awaitDispatchTurn(navigation: lane, current: { waiting = true; return true })
        }
        while !waiting { await Task.yield() }
        refresh.cancel()
        #expect(await refresh.value == false)
        #expect(lane.isDispatching)
        finish?.resume()
        while lane.isDispatching { await Task.yield() }
    }

    @Test func thumbnailDispatchWaitDoesNotRenewAnExpiredFirstFrameOrRetiredCapture() async {
        let lane = NativeSidebarNavigation()
        var finish: CheckedContinuation<Void, Never>?
        lane.submit(stage: true) { _ in await withCheckedContinuation { finish = $0 } }
        while finish == nil { await Task.yield() }
        let acquired: TimeInterval = 100
        var now = acquired, waiting = false
        let refresh = Task {
            await DesktopWindowGallery.awaitDispatchTurn(navigation: lane, current: {
                waiting = true
                return now - acquired <= 5
            })
        }
        while !waiting { await Task.yield() }
        now = 105.001
        #expect(await refresh.value == false)
        #expect(lane.isDispatching)
        finish?.resume()
        while lane.isDispatching { await Task.yield() }
    }

    @Test func groupOwnerExcludesQueuedAndNewFocusAndDragBeforePreparation() async {
        let router = NativeSidebarNavigation()
        var owner = false, effects = [String]()
        var resume: CheckedContinuation<Void,Never>?
        router.stageOwnsWindowDispatch = { owner }
        router.submit(selection:false) { _ in await withCheckedContinuation { resume = $0 } }
        while resume == nil { await Task.yield() }
        router.submit(selection:false) { _ in effects.append("queued drag") }
        owner = true
        router.submit(prepare:{ effects.append("ordinary focus preparation") }) { _ in effects.append("ordinary focus") }
        router.submit(stage:true) { _ in effects.append("group") }
        resume?.resume()
        for _ in 0..<100 where effects.isEmpty { await Task.yield() }
        #expect(effects == ["group"])
    }

    @Test func newerChoiceSuppressesOldPostSwitchFocusAndCoalescesIntermediateIntent() async {
        let router = NativeSidebarNavigation()
        var resume: CheckedContinuation<Void, Never>?, effects = [String]()
        router.submit { token in
            effects.append("switch")
            await withCheckedContinuation { resume = $0 }
            if router.isCurrent(token) { effects.append("stale focus") }
        }
        while resume == nil { await Task.yield() }
        router.submit { _ in effects.append("intermediate") }
        router.submit { _ in effects.append("latest") }
        resume?.resume()
        for _ in 0..<100 where effects.count < 2 { await Task.yield() }
        #expect(effects == ["switch", "latest"])
    }
    @Test func interveningQueuedMoveCannotResurrectAnOlderStageSelection() async {
        let router = NativeSidebarNavigation()
        var resume: CheckedContinuation<Void, Never>?, effects = [String]()
        router.submit(selection: false) { _ in await withCheckedContinuation { resume = $0 } }
        while resume == nil { await Task.yield() }
        router.submit(stage: true) { _ in effects.append("old") }
        router.submit(selection: false) { _ in effects.append("move") }
        router.submit(stage: true) { _ in effects.append("latest") }
        resume?.resume()
        for _ in 0..<100 where effects.last != "latest" { await Task.yield() }
        #expect(effects == ["move", "latest"])
    }

    @Test func onlyANewerGroupChoiceInTheOriginalOwnershipEpochMayTakeOver() async throws {
        let router = NativeSidebarNavigation(), epoch = router.ownershipEpoch
        var original: UUID?, resume: CheckedContinuation<Void, Never>?
        router.submit(stage: true) { token in
            original = token
            await withCheckedContinuation { resume = $0 }
        }
        while resume == nil { await Task.yield() }
        defer { resume?.resume() }
        let token = try #require(original)
        router.submit(selection: false) { _ in }
        #expect(router.queuedGroupChoice(after: token, in: epoch) == nil)
        router.submit(stage: true) { _ in }
        let queued = try #require(router.queuedGroupChoice(after: token, in: epoch))
        router.submit(stage: true) { _ in }
        let last = try #require(router.queuedGroupChoice(after: token, in: epoch))
        #expect(queued != last && !router.isCurrent(queued) && router.isCurrent(last))
        router.setDispatchAvailable(false)
        router.setDispatchAvailable(true)
        router.submit(stage: true) { _ in }
        #expect(router.queuedGroupChoice(after: token, in: epoch) == nil)
    }

    @Test func subsequentSelectionCannotDiscardQueuedMove() async {
        let router = NativeSidebarNavigation()
        var resume: CheckedContinuation<Void, Never>?, effects = [String]()
        router.submit { _ in await withCheckedContinuation { resume = $0 } }
        while resume == nil { await Task.yield() }
        router.submit(selection: false) { _ in effects.append("move") }
        router.submit { _ in effects.append("intermediate") }
        router.submit { _ in effects.append("latest") }
        resume?.resume()
        for _ in 0..<100 where effects.count < 2 { await Task.yield() }
        #expect(effects == ["move", "latest"])
    }
    @Test func revocationCancelsOnlyFutureGestureSteps() {
        let permit = NativeSelectionPermit()
        let command = NativeSpaceCommand(id: UUID(), action: .select, display: "", source: "", target: "", createdAtUptime: 50)
        let started = permit.permission(for: command.id, after: 0)
        permit.revoke()
        #expect(started.permits(command, after: 0, now: 51))
        #expect(!permit.permission(for: command.id, after: 1).permits(command, after: 1, now: 51))
    }

    @Test func eachGestureRequiresTheOriginalAXElementEvenIfTheNumericIDIsReused() async {
        var element = UUID()
        let original = element
        let permit = NativeSelectionPermit(checkOriginalWindow: { element == original })
        let id = UUID()
        let first = await permit.gesturePermission(for: id, after: 0)
        #expect(first.proceed)
        element = UUID()
        let next = await permit.gesturePermission(for: id, after: 1)
        #expect(!next.proceed)
    }

    @Test func lateFocusWriteNeedsFreshIntentAndTheOriginalLifetime() {
        let original = UUID()
        var lifetime: UUID? = original
        var physicalPress: UInt32 = 0
        let permit = NativeSelectionPermit { lifetime == original && physicalPress == 0 }
        let request = OrdinaryWindowRequest(.focusCurrent, pid: 42, launch: 86, bundle: "org.fixture", focusDeadline: 4)
        let first = permit.permission(for: request.nonce, after: 0)
        #expect(first.permitsFocus(request, after: 0, now: 1))
        #expect(!first.permitsFocus(request, after: 1, now: 1))
        #expect(!first.permitsFocus(request, after: 0, now: 4))
        physicalPress += 1
        #expect(!permit.permission(for: request.nonce, after: 1).permitsFocus(request, after: 1, now: 2))
        physicalPress = 0
        lifetime = UUID()
        #expect(!permit.permission(for: request.nonce, after: 1).permitsFocus(request, after: 1, now: 2))
        lifetime = original
        permit.revoke()
        #expect(!permit.permission(for: request.nonce, after: 1).permitsFocus(request, after: 1, now: 2))
    }

}
