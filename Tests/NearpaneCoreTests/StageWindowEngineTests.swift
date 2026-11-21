import Foundation
import Testing
@testable import NearpaneCore

@MainActor private final class EngineFixture: StageEngineWindowWitness, StageEngineTransport {
    let scope = StageGroupScope(display:UUID(),nativeSpace:UUID()), epoch = UUID()
    let displayArea = SurfaceRect(width:1200,height:950)
    var sequence: UInt64 = 0, windows = [NativeSpaceWindow:StageWindowState](), focus: NativeSpaceWindow?
    var visible = [NativeSpaceWindow:StageWindowState](), writeIntents = Set<UUID>()
    var health = true, recovery = true, zeroLeases = true, unknownHide: UInt32?, badReadback: UInt32?
    var beforeCloseRead: (() -> Void)?
    var effects: [(UInt32,NativeSpaceWindow)] = [], ordinaryEffects: [StageWindowAction] = [], revokes = 0, closes = 0
    func permits(_ owner: StageEngineOwner, restoring: Bool) -> Bool { restoring ? recovery : health }
    func read(_ scope: StageGroupScope, owner: StageEngineOwner) async throws -> StageWindowSample {
        sequence += 1
        return .init(scope:self.scope,generation:epoch,sequence:sequence,workArea:displayArea,windows:windows,focus:focus,nativeID:22)
    }
    func ordinary(_ c: StageWindowCommand, valid: @escaping @MainActor () -> Bool) throws {
        guard valid() else { throw StageSwitchError.interrupted }
        ordinaryEffects.append(c.action)
        switch c.action {
        case .place(let f): windows[c.before.window]?.frame = f
        case .focus: focus = c.before.window
        default: throw StageSwitchError.ownership
        }
    }
    func submit(_ op: UInt32, owner: StageEngineOwner, _ c: StageWindowCommand) throws -> StageEngineReply {
        let id = c.before.window
        if [3,4,5].contains(op), !writeIntents.insert(c.intent).inserted { throw StageSwitchError.ownership }
        switch op {
        case 6: return .init(status:health ? 0 : 2,flags:health ? 64 | 16 | 32 : 0,intent:c.intent,nativeID:22)
        case 3:
            effects.append((op,id)); visible[id] = c.before
            windows[id]?.visibility = owner.backend == .corner ? .parked : .stageSpace
            windows[id]?.hiddenSpaceID = owner.backend == .spaces ? 60 : nil
            if c.before.window.number == unknownHide { throw StageSwitchError.incomplete }
        case 4,5:
            effects.append((op,id))
            guard let saved = visible.removeValue(forKey:id) else { throw StageSwitchError.ownership }
            windows[id] = saved
        case 2:
            let hidden = windows[id]?.visibility == .parked || windows[id]?.visibility == .stageSpace
            let flags: UInt32 = id.number == badReadback ? 0 : 4 | 8 | 16 | 32 | (hidden ? 2 | 128 : 1)
            return .init(status:0,flags:flags,intent:c.intent,nativeID:hidden && owner.backend == .spaces ? 60 : 22,frame:windows[id]?.frame)
        default: throw StageSwitchError.unavailable
        }
        return .init(status:0,flags:0,intent:c.intent,nativeID:22)
    }
    func revoke() { revokes += 1 }
    func close() async -> Bool {
        beforeCloseRead?()
        guard zeroLeases && visible.isEmpty else { return false }
        closes += 1
        return true
    }
}

@Suite @MainActor struct StageWindowEngineTests {
    let environment = StageEngineEnvironment(osBuild:"26A428",engineRevision:String(repeating:"a",count:40),
        hostCDHash:String(repeating:"1",count:40),hardware:"fixture",topology:"physical-fixture",windowClass:"ordinary",sipEnabled:true)
    private func qualification(_ backend: StageWindowBackend, _ comparison: StageEngineComparison? = nil) -> StageEngineQualification {
        .init(backend:backend,environment:environment,evidence:UUID(),
              checks:Dictionary(uniqueKeysWithValues:StageEngineCheck.required(for:backend).map { ($0,.pass) }),comparison:comparison)
    }
    private func metrics(_ n: Double, memory: Double = 2, sample: Int = 100, inputTail: Double? = nil) -> StageEngineComparison {
        .init(protocolDigest:"same-workload",samplesPerDirection:sample,
              firstFrame:.init(p50:n,p95:n+1,p99:n+2),interactive:.init(p50:n+1,p95:n+2,p99:inputTail ?? n+3),
              settled:.init(p50:n+2,p95:n+3,p99:n+4),longestSettling:n+5,frameGapP99:n+1,droppedFramePercent:0,
              idleCPU:1,burstCPU:2,windowServerCPU:2,replaydCPU:1,memoryMB:memory)
    }
    @Test func selectionUsesCompletePhysicalEvidenceAndNoBackendOrder() {
        let a=qualification(.corner,metrics(8)), b=qualification(.spaces,metrics(5))
        #expect(StageEngineQualification.choose([a,b],in:environment)==b)
        #expect(StageEngineQualification.choose([b,a],in:environment)==b)
        let fast=qualification(.corner,metrics(3))
        #expect(StageEngineQualification.choose([b,fast],in:environment)==fast)
        #expect(StageEngineQualification.choose([qualification(.corner,metrics(3,inputTail:75)),b],in:environment)==nil)
        let mixed=qualification(.corner,metrics(3,memory:15))
        #expect(StageEngineQualification.choose([mixed,b],in:environment)==nil)
        #expect(StageEngineQualification.choose([mixed,b],in:environment,retaining:.spaces)==b)
        #expect(StageEngineQualification.choose([qualification(.spaces,metrics(3,sample:99)),a],in:environment)==nil)
        for missing in [StageEngineFinding.unknown,.fail,.notRun,.blocked] {
            var checks=b.checks;checks[.sameAppSiblings]=missing
            let unsafe=StageEngineQualification(backend:.spaces,environment:environment,evidence:UUID(),checks:checks,comparison:metrics(1))
            #expect(StageEngineQualification.choose([unsafe,a],in:environment)==a)
        }
        let changed=StageEngineEnvironment(osBuild:"27B000",engineRevision:environment.engineRevision,hostCDHash:environment.hostCDHash,
            hardware:environment.hardware,topology:"next",windowClass:"ordinary",sipEnabled:true)
        #expect(StageEngineQualification.choose([a,b],in:changed)==nil)
        #expect(StageEngineQualification.choose([],in:environment)==nil)
    }

    private func setup(_ count: Int = 3) throws -> (URL, StageGroupStore, StageWindowEngineController, EngineFixture, [StageGroupDirectory.Group]) {
        let path = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let w=EngineFixture(), store=StageGroupStore(profile:path)
        for n in 1...count+1 {
            let id=NativeSpaceWindow(pid:n<=2 ? 10 : Int32(10+n),birth:200,number:UInt32(n)), life=UUID()
            let frame=SurfaceRect(x:Double(n)*10,y:30,width:120,height:80)
            w.windows[id] = .init(window:id,lifetime:life,frame:frame,visibility:.visible)
            if n<=count {
                try store.observe([.init(display:w.scope.display,identity:id,lifetime:life,
                    nativeSpace:w.scope.nativeSpace)])
            }
            if n==1 {w.focus=id}
        }
        let engine=StageWindowEngineController(coordinator:try StageGroupCoordinator(store:store,profile:path))
        return (path,store,engine,w,store.groups(in:w.scope))
    }
    private func bind(_ e: StageWindowEngineController, _ f: EngineFixture, _ q: StageEngineQualification) async throws {
        let ok=try await e.configure(for:environment,records:[q],exclusive:{true}) {
            StageEngineSession(owner:.init(qualification:$0,generation:f.epoch),witness:f,transport:f)
        }
        #expect(ok)
    }
    private func activate(_ group: StageGroupDirectory.Group, _ engine: StageWindowEngineController, _ f: EngineFixture) async throws {
        try await engine.activate(group.id,member:group.members[0].id,in:f.scope,consent:true,current:{true})
    }

    @Test func fullGroupCycleUsesOnlyOneBackendAndRestoresBystandersUnchanged() async throws {
        let (p,store,engine,f,groups)=try setup()
        defer {try? FileManager.default.removeItem(at:p)}
        let originals=f.windows
        let old=qualification(.spaces), next=qualification(.corner)
        try await bind(engine,f,old)
        for i in [0,1,2,0] {try await activate(groups[i],engine,f)}
        #expect(f.focus == groups[0].members[0].windowHint)
        #expect(f.effects.allSatisfy { $0.1.number<=3 });#expect(!f.ordinaryEffects.isEmpty)
        #expect(f.windows.first { $0.key.number==4 }?.value == originals.first { $0.key.number==4 }?.value)
        #expect(f.writeIntents.count == f.effects.count)
        #expect(store.activeGroup(in:f.scope)==groups[0].id)
        let fresh=EngineFixture()
        var invoked=false
        let selected=try await engine.configure(for:environment,records:[next],exclusive:{true}) { q in
            invoked=true
            #expect(f.windows == originals && f.effects.filter { $0.0==5 }.count == 2 && f.closes == 1)
            return StageEngineSession(owner:.init(qualification:q,generation:fresh.epoch),witness:fresh,transport:fresh)
        }
        #expect(selected && invoked && store.activeGroup(in:f.scope)==nil)
    }

    @Test func oneUnknownRustWriteBlocksReplacementButOtherConfirmedWindowsCanReturn() async throws {
        let (p,store,engine,f,groups)=try setup(4)
        defer {try? FileManager.default.removeItem(at:p)}
        try await bind(engine,f,qualification(.corner))
        f.unknownHide=3
        await #expect(throws:StageSwitchError.self) { try await activate(groups[0],engine,f) }
        #expect(engine.coordinator.requiresRecovery)
        var replacement=false
        await #expect(throws:StageSwitchError.recoveryRequired) {
            _ = try await engine.configure(for:environment,records:[qualification(.spaces)],exclusive:{true}) { _ in replacement=true;return nil }
        }
        #expect(!replacement && f.effects.filter { $0.0==5 }.map { $0.1.number } == [2])
        let oldCount=f.effects.count
        await #expect(throws:StageSwitchError.recoveryRequired) {try await engine.release()}
        #expect(f.effects.count==oldCount)
        let fromDisk=try StageGroupCoordinator(store:store,profile:p)
        #expect(fromDisk.hasWindowAuthority && fromDisk.requiresRecovery && fromDisk.retainedOwner==engine.session?.owner)
    }

    @Test func changedLifetimeOrExternalGeometryNeverUsedForRestoration() async throws {
        let (p,_,engine,f,groups)=try setup()
        defer {try? FileManager.default.removeItem(at:p)}
        try await bind(engine,f,qualification(.corner))
        try await activate(groups[0],engine,f)
        let id=groups[1].members[0].windowHint,old=try #require(f.windows[id])
        f.windows[id] = .init(window:id,lifetime:UUID(),frame:old.frame,visibility:old.visibility)
        engine.invalidate()
        await #expect(throws:StageSwitchError.recoveryRequired) {try await engine.release()}
        #expect(f.effects.filter { $0.0==5 }.map { $0.1.number } == [3])
        let count=f.effects.count
        await #expect(throws:StageSwitchError.self) {try await activate(groups[0],engine,f)}
        #expect(count==f.effects.count)
    }
    @Test func incompleteWorkerReadAfterConfirmedRestoresKeepsDurableOwnerAcrossRestart() async throws {
        let (p,store,engine,f,groups) = try setup()
        defer { try? FileManager.default.removeItem(at:p) }
        try await bind(engine,f,qualification(.corner))
        try await activate(groups[0],engine,f)
        let owner = engine.session?.owner
        f.zeroLeases = false
        await #expect(throws:StageSwitchError.recoveryRequired) { try await engine.release() }
        #expect(f.visible.isEmpty && f.closes == 0)
        let reopened = try StageGroupCoordinator(store:store,profile:p)
        #expect(reopened.hasWindowAuthority && reopened.retainedOwner == owner)
        var otherWriter = false
        await #expect(throws:StageSwitchError.recoveryRequired) {
            _ = try await engine.configure(for:environment,records:[qualification(.spaces)],exclusive:{true}) { _ in
                otherWriter = true; return nil
            }
        }
        #expect(!otherWriter && f.effects.filter { $0.0 == 5 }.count == 2)
    }

    @Test func takeoverDuringOldWorkerShutdownVetoesAlreadyRequestedReplacement() async throws {
        let (p,_,engine,f,groups) = try setup()
        defer { try? FileManager.default.removeItem(at:p) }
        try await bind(engine,f,qualification(.spaces))
        try await activate(groups[0],engine,f)
        f.beforeCloseRead = { [weak engine] in engine?.invalidate() }
        var replacement = false
        await #expect(throws:StageSwitchError.interrupted) {
            _ = try await engine.configure(for:environment,records:[qualification(.corner)],exclusive:{true}) { _ in
                replacement = true; return nil
            }
        }
        #expect(!replacement && engine.session == nil && !engine.holdsWindowDispatch)
        #expect(f.effects.filter { $0.0 == 5 }.count == 2 && f.closes == 1)
    }

}
