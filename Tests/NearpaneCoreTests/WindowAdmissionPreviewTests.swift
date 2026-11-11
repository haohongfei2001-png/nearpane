import Foundation
import Testing
@testable import NearpaneCore

struct WindowAdmissionPreviewTests {
    let display = SurfaceRect(x: -800, y: 0, width: 800, height: 1280)
    func context() -> AdmissionContext {
        var prefs = WorkspacePreferences()
        prefs.newWindow = .joinExisting
        return .init(display: "side", screen: display, usable: display, primary: false, settings: .init(), edge: .left,
                     preferences: prefs, recoveryClear: true, exclusive: true)
    }

    func pair(_ number: UInt32, first: Double = 10, element: UUID = UUID(),
              mutate: (inout AdmissionSample) -> Void = { _ in }) -> AdmissionPair {
        func sample(_ time: Double) -> AdmissionSample {
            var s = AdmissionSample(pid: 444, launch: 123, number: number, bundle: "fixture", uptime: time)
            s.element = element; s.axNumber = number
            s.cgFrame = SurfaceRect(x: -700, y: 100, width: 300, height: 240); s.axFrame = s.cgFrame
            s.minimum = .init(width: 60, height: 60); s.display = "side"; s.role = .ordinary; s.onScreen = true
            s.minimized = false; s.fullscreen = false; s.layer = 0; s.positionSettable = true; s.sizeSettable = true
            s.editGeneration = "first"; s.permission = true; s.recoveryVerified = true; s.stageManager = true
            s.selectionContinuity = true
            mutate(&s)
            return s
        }
        return .init(first: sample(first), second: sample(first + 0.12))
    }

    @Test func zeroThroughThreeAndBackUseTheRealDisplayAndUserPartition() throws {
        var ctx = context()
        let windows = (1...3).map { pair(UInt32($0)) }
        let a = try #require(windows[0].second.id)
        let b = try #require(windows[1].second.id)
        let c = try #require(windows[2].second.id)
        func show(_ n: Int) -> AdmissionPreviewResult {
            WindowAdmissionPreview.evaluate(Array(windows.prefix(n)), context: ctx, uptime: 10.3)
        }
        #expect(show(0).reasons == [.selection])
        #expect(show(1).status == .reviewable)
        #expect(show(1).proposed[a] == SurfaceRect(x: -700, width: 700, height: 1280))
        #expect(show(1).exitFrames[a] == windows[0].second.cgFrame)
        ctx.ratio = 0.6; ctx.swapped = true
        let two = show(2)
        #expect(two.status == .reviewable && two.proposed[b]?.width == 420 && two.proposed[a]?.x == -280)
        #expect(two.exitFrames[b] == SurfaceRect(x: -800, width: 480, height: 1280))
        let three = show(3)
        #expect(three.proposed[c] == SurfaceRect(x: -700, width: 350, height: 1280))
        #expect(three.proposed[a]?.height == 640 && three.proposed[b]?.x == -350)
        #expect(three.exitFrames == three.current)
        #expect(show(2).proposed == two.proposed)
        ctx.settings.placement = .floating
        ctx.hypothetical = true
        let floating = show(2)
        #expect(floating.workRect == display && floating.proposed[b]?.width == 480)
        #expect(floating.preparation == nil && floating.reasons == [.hypothetical])
    }

    @Test func archivedPresentationAndRebuildNeverBecomeRecoveryGeometry() throws {
        let archived = pair(179888) {
            $0.axFrame = SurfaceRect(x: -681, y: 64, width: 562, height: 422)
            $0.cgFrame = SurfaceRect(x: -64, y: 602, width: 49, height: 76)
        }
        let result = WindowAdmissionPreview.evaluate([archived], context: context(), uptime: 10.3)
        #expect(result.status == .insufficient && result.reasons.contains(.geometry))
        #expect(result.proposed.isEmpty && result.current.isEmpty && result.exitFrames.isEmpty)
        let first = pair(179888), rebuilt = pair(179888)
        var badNumber = first.second; badNumber.axNumber = 4444
        for second in [rebuilt.second, badNumber] {
            let denied = WindowAdmissionPreview.evaluate([.init(first: first.first, second: second)], context: context(), uptime: 10.3)
            #expect(denied.reasons.contains(.identity) && denied.preparation == nil && denied.current.isEmpty)
        }
        let copiedAX = pair(179889, element: try #require(first.second.element))
        for conflicting in [rebuilt, copiedAX] {
            let conflict = WindowAdmissionPreview.evaluate([first,conflicting], context: context(), uptime: 10.3)
            #expect(conflict.preparation == nil && conflict.reasons == [.duplicate] && conflict.current.isEmpty)
        }
    }

    @Test func unknownOrdinaryCapabilitiesAndExplicitExclusionsExplainTheirScope() {
        let ordinary = pair(7) { $0.minimum = nil; $0.editGeneration = nil; $0.recoveryVerified = false }
        var ctx = context(); ctx.exclusive = nil; ctx.recoveryClear = false
        let r = WindowAdmissionPreview.evaluate([ordinary], context: ctx, uptime: 10.3)
        #expect(r.status == .insufficient && r.current.count == 1 && r.exitFrames.isEmpty)
        for reason in [AdmissionReason.minimumUnknown, .editGeneration, .recovery, .unknownOwner, .pendingJournal] {
            #expect(r.reasons.contains(reason))
        }
        ctx.preferences.excludedApps = ["fixture"]
        #expect(WindowAdmissionPreview.evaluate([ordinary], context: ctx, uptime: 10.3).status == .ineligible)
        let reusedNumber = pair(7) { $0.selectionContinuity = false }
        let observed = WindowAdmissionPreview.evaluate([reusedNumber], context: context(), uptime: 10.3)
        #expect(observed.current.count == 1 && observed.reasons == [.selectionContinuity] && observed.exitFrames.isEmpty)
        #expect(observed.preparation == nil)
        let sheet = pair(8) { $0.role = .ineligible }
        let unsupported = pair(9) { $0.positionSettable = false }
        for w in [sheet, unsupported] {
            #expect(WindowAdmissionPreview.evaluate([w], context: context(), uptime: 10.3).status == .ineligible)
        }
    }

    @Test func insufficientPermissionMinimumAndExpiredSamplesCannotPrepare() {
        let denied = pair(7) { $0.permission = false }
        #expect(WindowAdmissionPreview.evaluate([denied], context: context(), uptime: 10.3).reasons.contains(.permission))
        let a = pair(1) { $0.minimum = SurfaceRect(width: 240, height: 200) }
        var ctx = context(); ctx.settings.measures[.reservedWidth] = .init(600)
        let result = WindowAdmissionPreview.evaluate([a], context: ctx, uptime: 10.3)
        #expect(result.reasons == [.minimumConflict] && result.preparation == nil && result.exitFrames.isEmpty)
        let repeated = AdmissionPair(first: a.first, second: a.first)
        #expect(WindowAdmissionPreview.evaluate([repeated], context: context(), uptime: 10.3).reasons.contains(.stale))
        #expect(WindowAdmissionPreview.evaluate([a], context: context(), uptime: 13.01).reasons.contains(.stale))
    }

    @Test func recheckingPreparedScopeBindsWindowIncarnationGeometryUserEditAndPolicy() throws {
        let element = UUID()
        let a = pair(5, element: element)
        let ctx = context()
        let prep = try #require(WindowAdmissionPreview.evaluate([a], context: ctx, uptime: 10.3).preparation)
        let fresh = pair(5, first: 10.4, element: element)
        #expect(prep.matchesFreshReview([fresh], context: ctx, uptime: 10.6))
        let rebuilt = pair(5, first: 10.4)
        let moved = pair(5, first: 10.4, element: element) { $0.cgFrame?.x += 2; $0.axFrame = $0.cgFrame }
        let edited = pair(5, first: 10.4, element: element) { $0.editGeneration = "second" }
        for w in [rebuilt, moved, edited] {
            #expect(!prep.matchesFreshReview([w], context: ctx, uptime: 10.6))
        }
        var changed = ctx; changed.recoveryClear = false
        #expect(!prep.matchesFreshReview([fresh], context: changed, uptime: 10.6))
        changed = ctx; changed.preferences.windows[try #require(fresh.second.id)] = .exclude
        #expect(!prep.matchesFreshReview([fresh], context: changed, uptime: 10.6))
        #expect(!prep.matchesFreshReview([fresh], context: ctx, uptime: 13.01))
    }

    @Test func ninthWindowProjectsOnlyFeasibleSplitAndDoesNotAllocateSpace() {
        let windows = (1...9).map { pair(UInt32($0)) }
        let projected = WindowAdmissionPreview.evaluate(windows, context: context(), uptime: 10.3)
        #expect(projected.status == .reviewable && projected.proposed.count == 9)
        #expect(projected.notes.contains(where: { $0.contains("新建空间能力关闭") }))
        var ctx = context(); ctx.preferences.overflow = .continuousSplit
        let split = WindowAdmissionPreview.evaluate(windows, context: ctx, uptime: 10.3)
        #expect(split.proposed == projected.proposed && split.notes.contains(where: { $0.contains("按当前设置继续分割") }))
    }

    @Test func enrolledWindowNeedsItsOwnOriginalBaselineAndWorkArea() throws {
        let a = pair(1), id = try #require(a.second.id)
        let m = ManagedMember(id, minimumWidth: 60, minimumHeight: 60, canResize: true)
        var ctx = context(); ctx.savedLayout = try ManagedWindowTiler(workspace: nil).adding(m, in: display)
        let unknown = WindowAdmissionPreview.evaluate([a], context: ctx, uptime: 10.3)
        #expect(unknown.reasons.contains(.recovery) && unknown.exitFrames.isEmpty)
        ctx.originalFrames[id] = SurfaceRect(x: -800, y: 140, width: 240, height: 200)
        let known = WindowAdmissionPreview.evaluate([a], context: ctx, uptime: 10.3)
        #expect(known.preparation != nil && known.exitFrames == ctx.originalFrames && known.current != known.exitFrames)
        ctx.originalFrames[id]?.x = 0
        #expect(WindowAdmissionPreview.evaluate([a], context: ctx, uptime: 10.3).preparation == nil)
    }

    @Test func savedPairHistorySurvivesPreviewingThirdJoinAndRemoval() throws {
        let windows = (1...3).map { pair(UInt32($0)) }
        let ids = try windows.map { try #require($0.second.id) }
        let members = ids.map { ManagedMember($0, minimumWidth: 60, minimumHeight: 60, canResize: true) }
        let saved = try ManagedWindowTiler(workspace: nil).adding(members[0], in: display).adding(members[1], in: display)
            .adjusting(path: [], axis: .columns, ratio: 0.625, in: display).swapping(ids[0], ids[1], in: display)
        var ctx = context()
        ctx.savedLayout = saved
        for (id, window) in zip(ids, windows) { ctx.originalFrames[id] = window.second.cgFrame }
        let join = WindowAdmissionPreview.evaluate(windows, context: ctx, uptime: 10.3)
        let work = try #require(join.workRect)
        let three = try saved.adding(members[2], in: work)
        let expectedThree = try three.frames(in: work)
        #expect(join.status == .reviewable && join.proposed == expectedThree)
        ctx.savedLayout = three
        let remove = WindowAdmissionPreview.evaluate(Array(windows.prefix(2)), context: ctx, uptime: 10.3)
        let expectedTwo = try saved.frames(in: work)
        #expect(remove.status == .reviewable && remove.proposed == expectedTwo)
        #expect(remove.exitFrames == (try saved.frames(in: display)))
        ctx.originalFrames.removeValue(forKey: ids[1])
        let missing = WindowAdmissionPreview.evaluate(Array(windows.prefix(2)), context: ctx, uptime: 10.3)
        #expect(missing.exitFrames.isEmpty && missing.reasons == [.recovery])
    }
}
