import Foundation
import Testing
@testable import NearpaneCore

private final class FixtureActionAdapter: WorkspaceActionAdapter {
    let mode: WorkspaceMode
    init(_ mode: WorkspaceMode) { self.mode = mode }
    var applied = [WorkspaceMutation](), restored = 0, wrongReceipt = false, denyRestore = false
    func apply(_ change: WorkspaceMutation) throws -> WorkspaceReadback {
        applied.append(change)
        var frames = [ManagedWindowID: SurfaceRect]()
        for (id, layout) in change.layouts {
            frames.merge(try layout.frames(in: change.before.rows[id]!.area)) { a,_ in a }
        }
        var active: WorkspaceID?
        if case .switchRow(let id) = change.intent { active = id }
        return .init(operation: wrongReceipt ? UUID() : change.operation, session: change.before.session,
                     revision: change.before.revision + 1, active: active,
                     membership: change.layouts.mapValues { Set($0.members.map(\.id)) }, frames: frames)
    }
    func rollback(_ change: WorkspaceMutation) throws {
        restored += 1
        if denyRestore { throw WorkspaceFailure.conflict }
    }
}

private final class ModeOwner: WorkspaceModeTransaction {
    var transfers = 0, restores = 0, fail = false, conflict = false
    func transfer(from: WorkspaceMode, to: WorkspaceMode, preflight: ModePreflight) throws {
        transfers += 1; if fail { throw WorkspaceFailure.permission }
    }
    func restore(from: WorkspaceMode, preflight: ModePreflight) throws {
        restores += 1; if conflict { throw WorkspaceFailure.conflict }
    }
}

struct WorkspaceInteractionTests {
    let area = SurfaceRect(width: 900, height: 700)
    let window = WorkspaceLayoutTests().member(1)
    let session = UUID()
    private func snapshot(_ mode: WorkspaceMode = .native, destinationCount: Int = 1, width: Double = 900,
                          grant: Bool = true, revision: UInt64 = 7) throws -> (WorkspaceSnapshot, WorkspaceID, WorkspaceID) {
        func id(_ n: Int) -> WorkspaceID {
            mode == .native ? .native(session: session, scope: "scope", record: String(n)) : .virtual(UUID())
        }
        let a = id(1), b = id(2), dst = SurfaceRect(width: width, height: 700)
        let source = try ManagedWindowTiler(workspace: a).adding(window, in: area)
        var target = ManagedWindowTiler(workspace: b)
        for i in 0..<destinationCount { target = try target.adding(WorkspaceLayoutTests().member(i+2), in: dst) }
        var grants = [String: WorkspaceCapabilities]()
        for display in ["portrait","wide"] {
            grants[display] = .init(mode: mode, build: "fixture", displayID: display,
                                    actions: grant ? [.switchRow,.moveMember,.tile] : [], evidence: .isolated)
        }
        return (.init(session: session, revision: revision, mode: mode, build: "fixture", validUntil: 12,
                      rows: [a:.init(id:a,display:"portrait",area:area,layout:source),b:.init(id:b,display:"wide",area:dst,layout:target)],
                      grants: grants, stable: true),a,b)
    }
    @Test(arguments: [WorkspaceMode.native, .virtual])
    func clickSwitchesRowAndDropOnlyMovesExactMember(_ mode: WorkspaceMode) throws {
        let (s,a,b) = try snapshot(mode), n = FixtureActionAdapter(.native), v = FixtureActionAdapter(.virtual)
        let owner = mode == .native ? n : v, other = mode == .native ? v : n
        var r = WorkspaceGestureRouter(isolated: true)
        r.down(row:a,window:window.id,x:0,y:0,snapshot:s)
        #expect(try r.release(on:a,x:5,y:0,current:s,uptime:9,native:n,virtual:v) == .switchRow(a))
        r.down(row:a,window:window.id,x:0,y:0,snapshot:s)
        r.moved(x:6,y:0)
        #expect(owner.applied.count == 1)
        #expect(try r.release(on:b,x:8,y:0,current:s,uptime:9,native:n,virtual:v) == .move(window.id,from:a,to:b))
        #expect(owner.applied.last?.layouts[a]?.members.isEmpty == true)
        #expect(owner.applied.last?.layouts[b]?.members.last?.id == window.id)
        #expect(other.applied.isEmpty && owner.restored == 0)
        #expect(throws: WorkspaceFailure.stale) { try r.release(on:b,x:8,y:0,current:s,uptime:9,native:n,virtual:v) }
    }
    @Test func cancelledOrReturnedDragNeverBecomesClick() throws {
        let (s,a,b) = try snapshot(), n = FixtureActionAdapter(.native), v = FixtureActionAdapter(.virtual)
        var r = WorkspaceGestureRouter(isolated: true)
        r.down(row:a,window:nil,x:0,y:0,snapshot:s); r.moved(x:25,y:0)
        #expect(throws: WorkspaceFailure.membership) { try r.release(on:a,x:0,y:0,current:s,uptime:9,native:n,virtual:v) }
        r.down(row:a,window:window.id,x:0,y:0,snapshot:s); r.cancel()
        #expect(throws: WorkspaceFailure.stale) { try r.release(on:b,x:60,y:0,current:s,uptime:9,native:n,virtual:v) }
        #expect(n.applied.isEmpty && v.applied.isEmpty)
    }
    @Test func stalePermissionCapacityMinimumAndIncarnationBlockBeforeAdapter() throws {
        let n = FixtureActionAdapter(.native), v = FixtureActionAdapter(.virtual)
        for (count,width,grant,now,id,error) in [(8,900.0,true,9.0,window.id,WorkspaceFailure.capacity),
            (1,32,true,9,window.id,.minimumSize), (1,900,false,9,window.id,.unavailable),
            (1,900,true,13,window.id,.stale), (1,900,true,9,WorkspaceLayoutTests().member(1).id,.membership)] {
            let (s,a,b) = try snapshot(destinationCount:count,width:width,grant:grant)
            var r = WorkspaceGestureRouter(isolated:true)
            r.down(row:a,window:id,x:0,y:0,snapshot:s)
            #expect(throws: error) { try r.release(on:b,x:72,y:0,current:s,uptime:now,native:n,virtual:v) }
        }
        let (s,a,b) = try snapshot(), (changed,_,_) = try snapshot(revision:8)
        var r = WorkspaceGestureRouter(isolated:true)
        r.down(row:a,window:window.id,x:0,y:0,snapshot:s)
        #expect(throws: WorkspaceFailure.stale) { try r.release(on:b,x:9,y:0,current:changed,uptime:9,native:n,virtual:v) }
        var shipping = WorkspaceGestureRouter()
        shipping.down(row:a,window:nil,x:0,y:0,snapshot:s)
        #expect(throws: WorkspaceFailure.unavailable) { try shipping.release(on:a,x:0,y:0,current:s,uptime:9,native:n,virtual:v) }
        #expect(n.applied.isEmpty && v.applied.isEmpty)
    }
    @Test func failedReadbackRollsBackAndFailedRestorationLocksFurtherWrites() throws {
        let (s,a,b) = try snapshot(), n = FixtureActionAdapter(.native), v = FixtureActionAdapter(.virtual)
        var r = WorkspaceGestureRouter(isolated:true)
        n.wrongReceipt = true
        for fail in [false,true] {
            r.down(row:a,window:window.id,x:0,y:0,snapshot:s); n.denyRestore = fail
            #expect(throws: fail ? WorkspaceFailure.recoveryRequired : .stale) {
                try r.release(on:b,x:20,y:0,current:s,uptime:9,native:n,virtual:v)
            }
        }
        #expect(n.restored == 2 && r.needsRecovery)
        r.down(row:a,window:nil,x:0,y:0,snapshot:s)
        #expect(throws: WorkspaceFailure.stale) { try r.release(on:a,x:0,y:0,current:s,uptime:9,native:n,virtual:v) }
    }
    @Test func modeTransactionRequiresCurrentPermissionExclusiveOwnershipAndRestoration() throws {
        func check(_ mode: WorkspaceMode, rev: UInt64 = 1, busy: Bool = false) -> ModePreflight {
            .init(revision:rev,capabilities:.init(mode:mode,build:"fixture",displayID:"screen",actions:[.selectMode],evidence:.isolated),
                  affected:[window.id],permission:true,otherOwner:false,domainsBusy:busy,recoverable:true)
        }
        var shipping = WorkspaceModeCoordinator(), fixture = WorkspaceModeCoordinator(isolated:true)
        let owner = ModeOwner()
        #expect(shipping.mode == .native)
        #expect(throws: WorkspaceFailure.unavailable) { try shipping.prepare(check(.virtual)) }
        #expect(throws: WorkspaceFailure.conflict) { try fixture.prepare(check(.virtual,busy:true)) }
        let first = try fixture.prepare(check(.virtual))
        #expect(throws: WorkspaceFailure.conflict) { try fixture.prepare(check(.virtual)) }
        #expect(throws: WorkspaceFailure.stale) { try fixture.commit(first,current:check(.virtual,rev:2),owner:owner) }
        #expect(owner.transfers == 0)
        let token = try fixture.prepare(check(.virtual))
        try fixture.commit(token,current:check(.virtual),owner:owner)
        #expect(fixture.mode == .virtual)
        owner.fail = true
        let reject = try fixture.prepare(check(.native))
        #expect(throws: WorkspaceFailure.permission) { try fixture.commit(reject,current:check(.native),owner:owner) }
        #expect(fixture.mode == .virtual && owner.restores == 1)
        owner.conflict = true
        let interrupted = try fixture.prepare(check(.native))
        #expect(throws: WorkspaceFailure.recoveryRequired) { try fixture.commit(interrupted,current:check(.native),owner:owner) }
        #expect(fixture.needsRecovery && fixture.mode == .virtual)
    }

    @Test func fullscreenUsesExplicitEntryManualToolsAndConfirmedReturn() throws {
        let (s,a,_) = try snapshot()
        let layout = try #require(s.rows[a]?.layout), caps = try #require(s.grants["portrait"])
        let origin = FullscreenOrigin(session:session,workspace:a,display:"portrait",window:window.id,revision:7,layout:layout)
        let work = try DesktopWorkArea(display:"portrait",screen:area,usable:area,primary:true,settings:.init(),fallbackEdge:.right)
        var f = FullscreenTransitionCoordinator()
        #expect(throws: WorkspaceFailure.identity) { try f.enter(origin,verifiedNative:false,separate:false,capabilities:caps) }
        #expect(throws: WorkspaceFailure.unavailable) { try f.enter(origin,verifiedNative:true,separate:true,capabilities:caps) }
        try f.enter(origin,verifiedNative:true,separate:false,capabilities:caps)
        #expect(f.phase == .native && !f.toolsOpen)
        f.clickStatusStrip(); #expect(f.toolsOpen)
        f.hideTools(); #expect(!f.toolsOpen && f.phase == .native)
        #expect(try f.exit(observedWindow:window.id) == origin)
        var stale = f
        #expect(throws: WorkspaceFailure.recoveryRequired) {
            try stale.confirmReturn(session:session,revision:7,workspace:a,area:work,window:window.id,actual:[:])
        }
        try f.confirmReturn(session:session,revision:8,workspace:a,area:work,window:window.id,actual:layout.frames(in:work.ordinary))
        #expect(f.phase == .ordinary && f.origin == nil)
    }
    @Test func floatingAnchorMovesOnlyForConfirmedIntersectionAndPersists() throws {
        let original = SurfaceRect(x:30,y:20,width:40,height:20)
        var f = FloatingToolSurface(anchor:original)
        #expect(f.placement(safe:area,confirmedControls:[]) == original)
        let obstacle = SurfaceRect(x:65,y:18,width:30,height:70)
        #expect(f.placement(safe:area,confirmedControls:[obstacle]) == SurfaceRect(x:25,y:20,width:40,height:20))
        #expect(f.anchor == original && f.placement(safe:area,confirmedControls:[]) == original)
        f.userMoved(to:.init(x:700,y:300,width:40,height:20))
        #expect(try JSONDecoder().decode(FloatingToolSurface.self,from:JSONEncoder().encode(f)) == f)
        #expect(f.placement(safe:area,confirmedControls:[area]) == nil)
    }
}
