import Foundation
import Testing

@testable import NearpaneCore

struct WorkspacePolicyTests {
    let session = UUID(), area = SurfaceRect(x: -800, y: 0, width: 700, height: 1000)
    func row(_ count: Int, id: WorkspaceID) throws -> WorkspaceRowState {
        var tiler = ManagedWindowTiler(workspace: id)
        for i in 0..<count { tiler = try tiler.adding(WorkspaceLayoutTests().member(i + 1), in: area) }
        return .init(id: id, display: "fixture", area: area, layout: tiler)
    }
    func sample(
        _ rows: [WorkspaceRowState], grants: Set<WorkspaceAction>, prefs: WorkspacePreferences = .init(),
        revision: UInt64 = 1
    ) -> WorkspaceSnapshot {
        let mode = rows[0].id.mode
        return .init(
            session: session, revision: revision, mode: mode, build: "fixture", validUntil: 10,
            rows: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) }),
            grants: [
                "fixture": .init(mode: mode, build: "fixture", displayID: "fixture", actions: grants, evidence: .isolated)
            ],
            stable: true, preferences: prefs)
    }
    @Test(arguments: [WorkspaceMode.virtual, .native])
    func birthAndExplicitDropUseSeparatePreferencesAndSplitOnlyWhenAppropriate(_ mode: WorkspaceMode) throws {
        let id: WorkspaceID = mode == .virtual ? .virtual(UUID()) : .native(session: session, scope: "d", record: "witness")
        let member = WorkspaceLayoutTests().member(99)
        func plan(_ count: Int, _ source: AdmissionSource, _ prefs: WorkspacePreferences, _ grants: Set<WorkspaceAction>)
            throws -> WorkspaceAdmission
        {
            try WorkspaceAdmissionPlanner.plan(
                member: member, bundle: "fixture.app", role: .ordinary, source: source, target: id,
                snapshot: sample([try row(count, id: id)], grants: grants, prefs: prefs), preferences: prefs, uptime: 4,
                isolated: true)
        }
        var prefs = WorkspacePreferences()
        let all: Set<WorkspaceAction> = [.tile, .moveMember, .createWorkspace]
        #expect(try plan(1, .application, prefs, all).create)
        #expect(try !plan(1, .explicitDrop, prefs, all).create)
        prefs.newWindow = .joinExisting
        #expect(try plan(1, .application, prefs, all).existingLayout?.members.count == 2)
        for source in [AdmissionSource.application, .explicitDrop] {
            #expect(try plan(8, source, prefs, all).create)
            #expect(try plan(8, source, prefs, [.tile, .moveMember]).existingLayout?.members.count == 9)
        }
        prefs.overflow = .continuousSplit
        #expect(try plan(16, .explicitDrop, prefs, all).existingLayout?.members.count == 17)
        prefs.newWindow = .newWorkspace
        #expect(try plan(8, .application, prefs, all).create)
    }
    @Test func exclusionsAndWindowRolePrecedePlacementAndSurviveRestart() throws {
        let id = WorkspaceID.virtual(UUID())
        let m = WorkspaceLayoutTests().member(1)
        let r = try row(0, id: id)
        var prefs = WorkspacePreferences()
        prefs.excludedApps.insert("fixture.app")
        func check(_ role: ObservedWindowRole) throws -> WorkspaceAdmission {
            try WorkspaceAdmissionPlanner.plan(
                member: m, bundle: "fixture.app", role: role, source: .application, target: id,
                snapshot: sample([r], grants: [.tile], prefs: prefs), preferences: prefs, uptime: 4, isolated: true)
        }
        #expect(throws: WorkspaceFailure.excluded) { try check(.ordinary) }
        prefs.windows[m.id] = .include
        #expect(try check(.ordinary).existingLayout?.members == [m])
        #expect(throws: WorkspaceFailure.unmanaged) { try check(.sheet) }
        #expect(throws: WorkspaceFailure.unmanaged) { try check(.nativeFullscreen) }
        let reread = try JSONDecoder().decode(WorkspacePreferences.self, from: JSONEncoder().encode(prefs))
        #expect(try !reread.excluded(m.id, bundle: "fixture.app"))
        #expect(try reread.excluded(WorkspaceLayoutTests().member(1).id, bundle: "fixture.app"))
        #expect(throws: WorkspaceFailure.identity) { try reread.excluded(WorkspaceLayoutTests().member(2).id, bundle: nil) }
    }
    @Test func cleanupRequiresStablePostEventEmptySourceAndSeparateDeleteProof() throws {
        let id = WorkspaceID.native(session: session, scope: "scope", record: "source")
        let r = try row(0, id: id)
        let m = WorkspaceLayoutTests().member(2).id
        func e(
            _ complete: Bool = true, _ members: Set<ManagedWindowID> = [], _ active: Bool = false, _ last: Bool = false,
            _ event: Bool = true
        ) -> EmptySourceEvidence {
            .init(
                from: id, departed: m, session: session, beforeRevision: 1, afterRevision: 2, wasMember: true,
                causedByCloseOrMove: event,
                completeAllMembers: complete, remaining: members, active: active, protectedOrFullscreen: false,
                otherDesktopAvailable: !last)
        }
        let other = try row(1, id: .native(session: session, scope: "scope", record: "current"))
        let retained = sample([r, other], grants: [], revision: 2)
        let allowed = sample([r, other], grants: [.removeWorkspace], revision: 2)
        #expect(EmptyWorkspaceCleanup.evaluate(e(), current: retained, uptime: 2, isolated: true) == .pendingCapability)
        for event in [e(false), e(true, [m]), e(true, [], true), e(true, [], false, true), e(true, [], false, false, false)]
        {
            #expect(EmptyWorkspaceCleanup.evaluate(event, current: allowed, uptime: 2, isolated: true) == .preserve)
        }
        #expect(EmptyWorkspaceCleanup.evaluate(e(), current: allowed, uptime: 2, isolated: true) == .requestDeletion(id))
        #expect(!EmptyWorkspaceCleanup.confirmed(e(), after: allowed, completeInventory: true, uptime: 2))
    }
    @Test func hiddenAndRecalledPanelsNeverReflowDockedOrFloatingWorkAreas() throws {
        let f = SurfaceRect(x: -800, y: 10, width: 800, height: 1200)
        let screens = ["p", "s"].map { ScreenGeometry(id: $0, frame: f, visibleFrame: f) }
        var presentation = MultiDisplayPresentationCoordinator()
        var planner = WorkAreaLayoutPlanner()
        var settings = DisplaySettings()
        settings.policy = .pinned
        let tiler = try #require(try row(2, id: .virtual(UUID())).layout)
        func work() throws -> DesktopWorkArea {
            try .init(display: "s", screen: f, usable: f, primary: false, settings: settings, fallbackEdge: .left)
        }
        func plans() -> [PanelContent] {
            presentation.resolve(
                screens: screens, preferred: "p", settings: ["s": settings],
                demand: ["p": .init(spaces: 2, complete: true), "s": .init(spaces: 2, complete: true)], hidden: false,
                voice: true, tray: true, spacesEnabled: true, uptime: 5
            ).map(\.content)
        }
        #expect(try work().ordinary.width == 700)
        #expect(try planner.update(area: work(), layout: tiler)?.count == 2)
        #expect(plans() == [.full, .spacesOnly])
        presentation.dismiss("s")
        #expect(plans() == [.full, .hidden] && plans() == [.full, .hidden])
        presentation.dismiss("p")
        #expect(plans() == [.compact, .hidden])
        presentation.request("s")
        #expect(plans() == [.compact, .spacesOnly])
        #expect(try planner.update(area: work(), layout: tiler) == nil)
        settings.placement = .floating
        #expect(try work().ordinary == f)
        #expect(try planner.update(area: work(), layout: tiler)?.count == 2)
        presentation.dismiss("s")
        _ = plans()
        #expect(try planner.update(area: work(), layout: tiler) == nil)
        #expect(
            try DesktopWorkArea(display: "p", screen: f, usable: f, primary: true, settings: .init(), fallbackEdge: .right)
                .ordinary.width == 700)
    }
    @Test func quitPreservesUserPartitionWhileRelaunchUsesOnlyCurrentEligibleWindows() throws {
        let id = WorkspaceID.virtual(UUID())
        let r = try row(2, id: id)
        let auto = try #require(r.layout)
        let custom = try auto.adjusting(path: [], axis: .rows, ratio: 0.7, in: area)
        let changed = WorkspaceRowState(id: id, display: r.display, area: area, layout: custom)
        var s = sample([changed], grants: [.takeover, .tile])
        let full = SurfaceRect(x: -800, y: 0, width: 800, height: 1000)
        let saved = try custom.frames(in: area)
        let windows = try custom.members.map { m in
            LiveManagedWindow(
                member: m, bundle: "fixture", workspace: id, display: r.display, frame: try #require(saved[m.id]),
                ordinary: true)
        }
        let inputs = windows.map { w in
            ManagedBaseline(
                original: .init(
                    member: w.member, bundle: w.bundle, workspace: id, display: r.display,
                    frame: .init(x: -700, y: 10, width: 200, height: 200), ordinary: true), lastConfirmed: w)
        }
        let world = Dictionary(uniqueKeysWithValues: windows.map { ($0.member.id, $0) })
        s.observed = world
        let targets = WorkspaceRecovery.quit(
            inputs, live: world, current: s, usable: [r.display: full], uptime: 4, isolated: true)
        #expect(
            targets[windows[0].member.id]
                == .restore(workspace: id, display: r.display, frame: .init(x: -800, y: 0, width: 800, height: 700)))
        let original = WorkspaceRecovery.quit(
            inputs, live: world, current: sample([r], grants: [.tile]), usable: [r.display: full], uptime: 4, isolated: true)
        #expect(
            original[windows[0].member.id] == .restore(workspace: id, display: r.display, frame: inputs[0].original.frame))
        #expect(
            WorkspaceRecovery.quit(inputs, live: [:], current: s, usable: [r.display: full], uptime: 4, isolated: true)
                .values.allSatisfy { $0 == .needsAttention })
        func pre(_ settled: Bool) -> TakeoverPreflight {
            .init(
                explicitlyLaunched: true, priorGrant: true, journalSettled: settled, exclusive: true, inventoryComplete: true
            )
        }
        #expect(
            try WorkspaceRecovery.relaunch(pre(true), current: s, windows: windows, uptime: 4, isolated: true) == windows)
        #expect(throws: WorkspaceFailure.recoveryRequired) {
            try WorkspaceRecovery.relaunch(pre(false), current: s, windows: windows, uptime: 4, isolated: true)
        }
        #expect(throws: WorkspaceFailure.unavailable) {
            try WorkspaceRecovery.relaunch(pre(true), current: s, windows: windows, uptime: 4, isolated: false)
        }
        var excluded = s
        excluded.preferences.windows[windows[0].member.id] = .exclude
        #expect(
            try WorkspaceRecovery.relaunch(pre(true), current: excluded, windows: windows, uptime: 4, isolated: true) == [
                windows[1]
            ])
        #expect(
            WorkspaceRecovery.quit(
                inputs, live: world, current: excluded, usable: [r.display: full], uptime: 4, isolated: true)[
                    windows[0].member.id] == .leaveExcluded)
    }
}

private final class AllocationFixture: WorkspaceActionAdapter {
    let mode: WorkspaceMode = .native
    var receipts = [WorkspaceMutation](), rolls = 0
    var emitsUnchanged = false, spuriousMembership = false
    func apply(_ change: WorkspaceMutation) throws -> WorkspaceReadback {
        receipts.append(change)
        let a = try #require(change.admission)
        let target = try #require(change.before.rows[a.destination])
        if a.create && emitsUnchanged {
            let old = change.before
            var next = WorkspaceSnapshot(
                session: old.session, revision: old.revision + 1, mode: old.mode, build: old.build,
                validUntil: old.validUntil,
                rows: old.rows, grants: old.grants, stable: true, preferences: old.preferences)
            next.observed = old.observed
            next.bundles = old.bundles
            throw AllocationUnchanged(sample: next)
        }
        var members = change.before.rows.mapValues { Set($0.layout!.members.map(\.id)) }
        var frames = [ManagedWindowID: SurfaceRect]()
        var new: WorkspaceRowState?
        if a.create {
            let id = WorkspaceID.native(session: change.before.session, scope: "fixture", record: "new-observed-test-id")
            let result = try ManagedWindowTiler(workspace: id).adding(a.member, in: target.area)
            new = .init(id: id, display: target.display, area: target.area, layout: result)
            frames = try result.frames(in: target.area)
            members[id] = [a.member.id]
            if spuriousMembership { members[a.destination, default: []].insert(a.member.id) }
        } else {
            for (id, t) in change.layouts {
                members[id] = Set(t.members.map(\.id))
                frames.merge(try t.frames(in: target.area)) { _, b in b }
            }
        }
        return .init(
            operation: change.operation, session: change.before.session, revision: change.before.revision + 1,
            active: new?.id,
            membership: members, frames: frames, created: new)
    }
    func rollback(_ change: WorkspaceMutation) throws { rolls += 1 }
}
extension WorkspacePolicyTests {
    @Test func runtimeCreationFallbackRequiresUnchangedWorldAndBirthCannotReplay() throws {
        let id = WorkspaceID.native(session: session, scope: "fixture", record: "old")
        let base = try row(8, id: id)
        let previous = sample([base], grants: [.tile, .createWorkspace, .moveMember])
        var s = sample([base], grants: [.tile, .createWorkspace, .moveMember], revision: 2)
        let w = LiveManagedWindow(
            member: WorkspaceLayoutTests().member(90), bundle: "fixture", workspace: id, display: "fixture", frame: area,
            ordinary: true)
        s.observed[w.member.id] = w
        let fixture = AllocationFixture()
        fixture.emitsUnchanged = true
        var reused = previous
        var denied = NewWindowAdmissionCoordinator()
        reused.observed[w.member.id] = w
        #expect(throws: WorkspaceFailure.stale) {
            try denied.appeared(
                w, role: .ordinary, previous: reused, snapshot: s, uptime: 4, isolated: true, adapter: fixture)
        }
        #expect(fixture.receipts.isEmpty)
        var route = NewWindowAdmissionCoordinator()
        try route.appeared(w, role: .ordinary, previous: previous, snapshot: s, uptime: 4, isolated: true, adapter: fixture)
        #expect(fixture.receipts.map(\.admission?.create) == [true, false] && fixture.rolls == 0)
        #expect(
            fixture.receipts[1].layouts[id]?.members.count == 9
                && fixture.receipts[0].operation == fixture.receipts[1].operation)
        #expect(throws: WorkspaceFailure.conflict) {
            try route.appeared(
                w, role: .ordinary, previous: previous, snapshot: s, uptime: 4, isolated: true, adapter: fixture)
        }
        #expect(fixture.receipts.count == 2)
        for duplicated in [false, true] {
            let fresh = AllocationFixture()
            fresh.spuriousMembership = duplicated
            var birth = NewWindowAdmissionCoordinator()
            if duplicated {
                #expect(throws: WorkspaceFailure.stale) {
                    try birth.appeared(
                        w, role: .ordinary, previous: previous, snapshot: s, uptime: 4, isolated: true, adapter: fresh)
                }
                #expect(fresh.rolls == 1 && fresh.receipts.count == 1)
            } else {
                try birth.appeared(
                    w, role: .ordinary, previous: previous, snapshot: s, uptime: 4, isolated: true, adapter: fresh)
                #expect(fresh.receipts.count == 1 && fresh.rolls == 0)
            }
        }
    }
}
