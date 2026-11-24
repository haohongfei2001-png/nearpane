import Foundation
import Testing
@testable import NearpaneCore

@MainActor private final class EngineFixture: StageEngineWindowWitness, StageEngineTransport {
    func checkRetirementSurface(_ scope: StageGroupScope, nativeID: UInt64, bottomOnly: Bool, owner: StageEngineOwner) throws {
        guard scope == self.scope && nativeID == 22 else { throw StageSwitchError.unavailable }
    }
    func mayManage(_ state: StageWindowState) -> Bool { true }
    let scope = StageGroupScope(display:UUID(),nativeSpace:UUID()), epoch = UUID()
    let displayArea = SurfaceRect(width:1200,height:950)
    var sequence: UInt64 = 0, windows = [NativeSpaceWindow:StageWindowState](), focus: NativeSpaceWindow?
    var visible = [NativeSpaceWindow:StageWindowState](), writeIntents = Set<UUID>()
    var health = true, recovery = true, zeroLeases = true, canStart = true, unknownHide: UInt32?, badReadback: UInt32?
    var measuredHide: UInt32?, beforeMeasuredReturn: (() throws -> Void)?
    var secondBystanderRead: (() -> Void)?, bystanderReads = 0
    var measuredWrites = [UUID](), failReturnConfirmation = false
    var workerHealthy = true
    var obstructWhenRetired = false
    var beforeRead: (() -> Void)?
    var beforeCloseRead: (() -> Void)?
    var prepared = Set<UUID>(), confirmed = Set<UUID>(), confirmationFailure: UInt32?
    var delayedRelease: UUID?, holdReleaseReceipt = false, lateReleaseReads = [UUID]()
    enum Withdrawal: Sendable { case confirmed, denied, lostReply }
    var withdrawal: Withdrawal = .denied
    var loseHideTransportAfterAdmission: Bool?
    var afterPrepare: ((StageWindowCommand) -> Void)?
    var afterVisibilityWrite: (() -> Void)?
    var prepareReplyLost = false, nextReadFails = false
    var withdrawalAttempts = [StageWindowCommand](), withdrawn = Set<UUID>()
    var visibleAfterMutation = [Int]()
    var effects: [(UInt32,NativeSpaceWindow)] = [], ordinaryEffects: [StageWindowAction] = [], revokes = 0, closes = 0
    func permits(_ owner: StageEngineOwner, restoring: Bool) -> Bool { restoring ? recovery : health }
    func read(_ scope: StageGroupScope, owner: StageEngineOwner) async throws -> StageWindowSample {
        beforeRead?()
        if nextReadFails { nextReadFails = false; throw StageSwitchError.incomplete }
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
    func readBystanders(of c: StageWindowCommand, measured: SurfaceRect, owner: StageEngineOwner) async throws -> StageWindowSample {
        guard windows[c.before.window]?.frame == measured else { throw StageSwitchError.ownership }
        bystanderReads += 1
        if bystanderReads == 2 { secondBystanderRead?() }
        sequence += 1
        return .init(scope:scope, generation:epoch, sequence:sequence, workArea:displayArea,
                     windows:windows.filter { $0.key != c.before.window }, focus:focus, nativeID:22)
    }
    func returnMeasured(_ proof: MeasuredCornerHide, intent: UUID, valid: @escaping @MainActor () -> Bool) throws -> StageEngineReply {
        let key = proof.command.before.window
        try beforeMeasuredReturn?()
        guard valid(), windows[key]?.frame == proof.landing, writeIntents.insert(intent).inserted,
              let original = visible.removeValue(forKey:key) else { throw StageSwitchError.interrupted }
        measuredWrites.append(intent)
        effects.append((5, key))
        windows[key] = original
        return .init(status:0, flags:45, intent:intent, nativeID:22, frame:original.frame)
    }
    func confirmMeasuredReturn(_ proof: MeasuredCornerHide, intent: UUID) throws {
        guard !failReturnConfirmation, measuredWrites.last == intent,
              windows[proof.command.before.window] == proof.command.before else { throw StageSwitchError.incomplete }
    }
    func submit(_ op: UInt32, owner: StageEngineOwner, _ c: StageWindowCommand) throws -> StageEngineReply {
        let id = c.before.window
        if op == 3, loseHideTransportAfterAdmission == false { throw CornerHideAdmissionRefused(StageSwitchError.incomplete) }
        if [3,4,5].contains(op), withdrawn.contains(c.intent) || !writeIntents.insert(c.intent).inserted { throw StageSwitchError.ownership }
        if op == 3, loseHideTransportAfterAdmission == true { throw StageSwitchError.incomplete }
        switch op {
        case 6: return .init(status:health ? 0 : 2,flags:health ? 64 | 16 | 32 : 0,intent:c.intent,nativeID:22)
        case 3:
            effects.append((op,id)); visible[id] = c.before
            windows[id]?.visibility = owner.backend == .corner ? .parked : .stageSpace
            windows[id]?.hiddenSpaceID = owner.backend == .spaces ? 60 : nil
            if id.number == measuredHide {
                let landing = SurfaceRect(x:displayArea.width-4, y:displayArea.height-4,
                                          width:c.before.frame.width, height:c.before.frame.height)
                windows[id]?.frame = landing
                throw MeasuredCornerHide(owner:owner, command:c, landing:landing)
            }
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
        visibleAfterMutation.append(windows.values.filter { $0.visibility == .visible }.count)
        afterVisibilityWrite?()
        return .init(status:0,flags:0,intent:c.intent,nativeID:22)
    }
    func start(_ owner: StageEngineOwner,nativeID: UInt64) async throws { guard canStart && nativeID == 22 else { throw StageSwitchError.incomplete } }
    func prepareHide(_ c: StageWindowCommand, owner: StageEngineOwner) async throws {
        guard owner.backend == .corner, !writeIntents.contains(c.intent), prepared.insert(c.intent).inserted else { throw StageSwitchError.ownership }
        if prepareReplyLost { throw StageSwitchError.incomplete }
        afterPrepare?(c)
    }
    func withdrawUnsubmittedHide(_ c: StageWindowCommand, owner: StageEngineOwner) async throws -> Bool {
        withdrawalAttempts.append(c)
        guard c.action == .hide, owner.backend == .corner, owner.generation == c.generation,
              prepared.contains(c.intent), !writeIntents.contains(c.intent) else { return false }
        switch withdrawal {
        case .confirmed: return withdrawn.insert(c.intent).inserted
        case .denied: return false
        case .lostReply: throw StageSwitchError.incomplete
        }
    }
    func verified(_ c: StageWindowCommand, after: StageWindowState, owner: StageEngineOwner) async throws {
        if c.restoring && c.action == .show && holdReleaseReceipt {
            delayedRelease = c.intent
            throw StageSwitchError.recoveryRequired
        }
        guard writeIntents.contains(c.intent), (c.action != .hide || prepared.contains(c.intent)),
              confirmed.insert(c.intent).inserted, after.window.number != confirmationFailure else { throw StageSwitchError.recoveryRequired }
    }
    func readsFinalRelease(_ c: StageWindowCommand, owner: StageEngineOwner) async -> Bool {
        lateReleaseReads.append(c.intent)
        return !holdReleaseReceipt && c.intent == delayedRelease && writeIntents.contains(c.intent)
    }
    func health(_ owner: StageEngineOwner, intent: UUID) async throws -> StageEngineReply {
        if obstructWhenRetired && !visible.isEmpty {
            return .init(status: 2, flags: 0, intent: intent, nativeID: 0, workAreaObstructed: true)
        }
        return .init(status:workerHealthy ? 0 : 2,flags:workerHealthy ? 64 | 16 : 0,intent:intent,nativeID:0)
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
        hostCDHash:String(repeating:"1",count:40),hardware:"fixture",topology:"physical-fixture",windowClass:"ordinary-standard",sipEnabled:true,permissions:Set(StageVisibilityPermission.allCases))
    private func qualification(_ backend: StageWindowBackend, _ comparison: StageEngineComparison? = nil) -> StageEngineQualification {
        .init(backend:backend,environment:environment,evidence:UUID(),
              checks:Dictionary(uniqueKeysWithValues:StageEngineCheck.required(for:backend).map { ($0,.pass) }),comparison:comparison ?? metrics(6))
    }
    private func metrics(_ n: Double, memory: Double = 2, sample: Int = 100, inputTail: Double? = nil) -> StageEngineComparison {
        .init(protocolDigest:"same-workload",samplesPerDirection:sample,
              firstFrame:.init(p50:n,p95:n+1,p99:n+2),interactive:.init(p50:n+1,p95:n+2,p99:inputTail ?? n+3),
              settled:.init(p50:n+2,p95:n+3,p99:n+4),longestSettling:n+5,frameGapP99:n+1,droppedFramePercent:0,
              idleCPU:1,burstCPU:2,windowServerCPU:2,replaydCPU:1,memoryMB:memory,
              reference:.init(appleFirstFrameP95:55,appleInteractiveP95:75,nominalInterval:16.7,frameGapP95:5,longestGap:18,recoverySeconds:1))
    }
    @Test func productNeverSelectsNativeSpacesEvenWithEveryFindingAndBetterTiming() {
        let corner = qualification(.corner), spaces = qualification(.spaces, metrics(1))
        #expect(StageEngineQualification.choose([spaces], in: environment) == nil)
        #expect(StageEngineQualification.choose([spaces, corner], in: environment) == corner)
        #expect(StageEngineQualification.choose([corner, spaces], in: environment, excluding: [corner.evidence]) == nil)
        #expect(StageEngineQualification.choose([corner, qualification(.corner)], in: environment) == nil)
        #expect(!qualification(.corner, metrics(275)).admits(environment))
        #expect(WindowVisibilityProvider.admission(for: spaces, in: environment, stage: .isolatedGroupTrial) == .unsupported)
    }

    @Test func isolatedSingleWindowProofNeverEnablesShippingAndMissingEvidenceNeverAdmitsAGroup() throws {
        let approved = qualification(.corner)
        var checks = Dictionary(uniqueKeysWithValues: WindowVisibilityProvider.corner.singleWindowChecks.map { ($0, StageEngineFinding.pass) })
        func record(_ e: StageEngineEnvironment) -> StageEngineQualification {
            .init(backend: .corner, environment: e, evidence: approved.evidence, checks: checks)
        }
        #expect(WindowVisibilityProvider.admission(for: record(environment), in: environment, stage: .isolatedGroupTrial) == .supported)
        #expect(!record(environment).admits(environment))
        for key in WindowVisibilityProvider.corner.singleWindowChecks {
            for outcome in [StageEngineFinding.unknown, .notRun, .blocked, .fail] {
                checks[key] = outcome
                #expect(WindowVisibilityProvider.admission(for: record(environment), in: environment, stage: .isolatedGroupTrial) == .unsupported)
            }
            checks[key] = .pass
        }
        for permission in StageVisibilityPermission.allCases {
            let e = StageEngineEnvironment(osBuild:environment.osBuild, engineRevision:environment.engineRevision,
                hostCDHash:environment.hostCDHash, hardware:environment.hardware, topology:environment.topology,
                windowClass:environment.windowClass, sipEnabled:true, permissions:WindowVisibilityProvider.corner.requiredPermissions.subtracting([permission]))
            #expect(WindowVisibilityProvider.admission(for: record(e), in:e, stage:.isolatedGroupTrial) == .unsupported)
        }
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(environment)) as? [String:Any])
        json.removeValue(forKey: "permissions")
        let legacy = try JSONDecoder().decode(StageEngineEnvironment.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.permissions == nil)
        #expect(WindowVisibilityProvider.admission(for: record(legacy), in:legacy, stage:.isolatedGroupTrial) == .unsupported)
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

    @Test(arguments: [false, true]) func aNewerGroupCanReuseOnlyIndependentlySettledWork(_ afterHide: Bool) async throws {
        let (profile, store, engine, f, groups) = try setup()
        defer { try? FileManager.default.removeItem(at: profile) }
        try await bind(engine, f, qualification(.corner))
        let target = groups[1], latest = groups[2]
        let departing = groups[0].members[0]
        f.windows[departing.windowHint]?.frame.x += 27
        let original = try #require(f.windows[departing.windowHint])
        let bystanders = f.windows.filter { $0.key.number > 3 }
        var queued = false
        f.withdrawal = .confirmed
        if afterHide { f.afterVisibilityWrite = { queued = true } }
        else { f.afterPrepare = { _ in queued = true } }
        await #expect(throws: StageSwitchError.superseded) {
            try await engine.activate(target.id, member: target.members[0].id, in: f.scope, consent: true,
                                      current: { !queued }, newerChoice: { queued })
        }
        #expect(f.revokes == 0 && !engine.coordinator.requiresRecovery)
        #expect(store.activeGroup(in: f.scope) == nil && f.ordinaryEffects == [.focus])
        let pending = try readJournal(profile)
        #expect(pending.pending == nil && pending.owned.count == (afterHide ? 1 : 0))
        if afterHide {
            #expect(f.prepared == f.confirmed && f.effects.count == 1)
            #expect(StageGroupStore(profile: profile).groups(in: f.scope)[0].members[0].layout ==
                    StageGroupWindow.relativeFrame(original.frame, in: f.displayArea))
        } else {
            #expect(f.effects.isEmpty && f.withdrawn == f.prepared && f.withdrawn.count == 1)
        }
        f.afterVisibilityWrite = nil
        f.afterPrepare = nil
        try await activate(latest, engine, f)
        #expect(f.focus == latest.members[0].windowHint && store.activeGroup(in: f.scope) == latest.id)
        try await activate(groups[0], engine, f)
        #expect(f.windows[departing.windowHint] == original && f.windows.filter { $0.key.number > 3 } == bystanders)
    }

    @Test func aQueuedClickCannotDischargeAnUnknownHide() async throws {
        let (profile, store, engine, f, groups) = try setup()
        defer { try? FileManager.default.removeItem(at: profile) }
        try await bind(engine, f, qualification(.corner))
        var queued = false
        f.afterVisibilityWrite = { queued = true }
        f.badReadback = groups[0].members[0].windowHint.number
        await #expect(throws: StageSwitchError.incomplete) {
            try await engine.activate(groups[1].id, member: groups[1].members[0].id, in: f.scope, consent: true,
                                      current: { !queued }, newerChoice: { queued })
        }
        #expect(queued && engine.coordinator.requiresRecovery && engine.session?.isFrozen == true)
        #expect(f.effects.count == 1 && store.activeGroup(in: f.scope) == nil)
        let entry = try #require(readJournal(profile).pending?.entries.last)
        #expect(entry.action == .hide && entry.after == nil)
    }

    @Test func aBystanderChangeDuringHandoffRetainsTheSealedLease() async throws {
        let (profile, store, engine, f, groups) = try setup()
        defer { try? FileManager.default.removeItem(at: profile) }
        try await bind(engine, f, qualification(.corner))
        let bystander = try #require(f.windows.keys.first { $0.number == 4 })
        var queued = false, observations = 0
        f.afterVisibilityWrite = { queued = true }
        f.beforeRead = { [unowned f] in
            if queued && !f.confirmed.isEmpty {
                observations += 1
                if observations == 2 { f.windows[bystander]?.frame.x += 15 }
            }
        }
        await #expect(throws: StageSwitchError.interrupted) {
            try await engine.activate(groups[1].id, member: groups[1].members[0].id, in: f.scope, consent: true,
                                      current: { !queued }, newerChoice: { queued })
        }
        #expect(observations == 2 && engine.coordinator.requiresRecovery && f.effects.count == 1)
        let journal = try readJournal(profile)
        #expect(journal.pending != nil && journal.owned.count == 1 && store.activeGroup(in: f.scope) == nil)
    }

    @Test(arguments: [false, true]) func withdrawnHidePreservesEarlierIntentsAndTheUsersFocus(_ hasEarlierFocus: Bool) async throws {
        let (profile, store, engine, f, groups) = try setup()
        defer { try? FileManager.default.removeItem(at: profile) }
        try await bind(engine, f, qualification(.corner))
        let user = try #require(f.windows.keys.first { $0.number == 4 })
        let original = f.windows
        f.withdrawal = .confirmed
        f.afterPrepare = { [unowned f] _ in f.focus = user }
        await #expect(throws: StageSwitchError.interrupted) {
            try await activate(groups[hasEarlierFocus ? 1 : 0], engine, f)
        }
        let attempted = try #require(f.withdrawalAttempts.first)
        #expect(f.withdrawalAttempts.count == 1 && f.withdrawn == [attempted.intent] && f.effects.isEmpty)
        #expect(f.windows == original && f.focus == user && f.ordinaryEffects == (hasEarlierFocus ? [.focus] : []))
        let journal = try readJournal(profile)
        let proof = try #require(journal.lastWithdrawnHide)
        #expect(proof.owner == engine.session?.owner && proof.owner.generation == attempted.generation)
        #expect(proof.scope == attempted.scope && proof.nativeID == attempted.nativeID && proof.before == attempted.before)
        #expect(proof.intent == attempted.intent && proof.group == attempted.group && proof.member == attempted.member)
        #expect(journal.owned.isEmpty && journal.owner == proof.owner)
        let reopened = try StageGroupCoordinator(store: store, profile: profile)
        #expect(reopened.requiresRecovery == hasEarlierFocus && reopened.retainedOwner == journal.owner)
        if hasEarlierFocus {
            let earlier = try #require(journal.pending)
            #expect(earlier.intent == proof.transaction && earlier.yieldedFocus == user)
            #expect(earlier.entries.count == 1 && earlier.entries[0].action == .focus && earlier.entries[0].after != nil)
        }
        try await engine.release()
        #expect(f.closes == 1 && f.focus == user && f.windows == original && f.effects.isEmpty)
        #expect(f.ordinaryEffects == (hasEarlierFocus ? [.focus] : []))
        #expect(!engine.coordinator.hasWindowAuthority && store.activeGroup(in: f.scope) == nil)
        #expect(try readJournal(profile).lastInterruptedRelease?.focus == (hasEarlierFocus ? user : nil))
    }

    @Test(arguments: [EngineFixture.Withdrawal.denied, .lostReply])
    private func missingWorkerOrGuardianAcknowledgementRetainsTheMayHaveIssuedEntry(_ mode: EngineFixture.Withdrawal) async throws {
        let (profile, store, engine, f, groups) = try setup()
        defer { try? FileManager.default.removeItem(at: profile) }
        try await bind(engine, f, qualification(.corner))
        let user = try #require(f.windows.keys.first { $0.number == 4 })
        f.withdrawal = mode
        f.afterPrepare = { [unowned f] _ in f.focus = user }
        await #expect(throws: StageSwitchError.interrupted) { try await activate(groups[0], engine, f) }
        let journal = try readJournal(profile), entry = try #require(journal.pending?.entries.last)
        #expect(f.withdrawalAttempts.count == 1 && f.withdrawn.isEmpty && f.effects.isEmpty && f.ordinaryEffects.isEmpty)
        #expect(entry.intent == f.withdrawalAttempts.first?.intent && entry.after == nil && journal.lastWithdrawnHide == nil)
        #expect(try StageGroupCoordinator(store: store, profile: profile).requiresRecovery)
        await #expect(throws: StageSwitchError.recoveryRequired) { try await engine.release() }
        #expect(f.focus == user && f.effects.isEmpty && f.closes == 0)
    }

    @Test func lostPrepareReplyAndUnknownSubmittedHideCannotBeWithdrawn() async throws {
        for afterSubmit in [false, true] {
            let (profile, _, engine, f, groups) = try setup()
            defer { try? FileManager.default.removeItem(at: profile) }
            try await bind(engine, f, qualification(.corner))
            f.withdrawal = .confirmed
            if afterSubmit { f.unknownHide = 2 } else { f.prepareReplyLost = true }
            await #expect(throws: StageSwitchError.incomplete) { try await activate(groups[0], engine, f) }
            let journal = try readJournal(profile)
            #expect(f.prepared.count == 1 && f.withdrawalAttempts.isEmpty && journal.lastWithdrawnHide == nil)
            #expect(f.effects.count == (afterSubmit ? 1 : 0) && journal.pending?.entries.count == 1)
            #expect(journal.pending?.entries.first?.after == nil && engine.coordinator.requiresRecovery)
        }
    }

    @Test(arguments: [false, true]) func lostHideTransportMayWithdrawOnlyBeforeRustTakesTheTicket(_ admitted: Bool) async throws {
        let (profile, store, engine, f, groups) = try setup()
        defer { try? FileManager.default.removeItem(at: profile) }
        try await bind(engine, f, qualification(.corner))
        f.withdrawal = .confirmed
        f.loseHideTransportAfterAdmission = admitted
        await #expect(throws: admitted ? StageSwitchError.incomplete : .interrupted) {
            try await activate(groups[0], engine, f)
        }
        let journal = try readJournal(profile)
        #expect(f.withdrawalAttempts.count == (admitted ? 0 : 1) && f.prepared.count == 1 && f.effects.isEmpty)
        #expect(store.activeGroup(in: f.scope) == nil)
        if admitted {
            #expect(f.withdrawn.isEmpty && journal.lastWithdrawnHide == nil && engine.coordinator.requiresRecovery)
        } else {
            #expect(f.withdrawn == f.prepared && journal.lastWithdrawnHide != nil && journal.pending == nil)
        }
    }

    @Test func withdrawalRetainsExistingOwnershipAndTheEarlierConfirmedShow() async throws {
        let (profile, _, engine, f, groups) = try setup()
        defer { try? FileManager.default.removeItem(at: profile) }
        try await bind(engine, f, qualification(.corner))
        try await activate(groups[0], engine, f)
        let held = try #require(try readJournal(profile).owned.first { $0.group == groups[2].id })
        let user = try #require(f.windows.keys.first { $0.number == 4 })
        f.withdrawal = .confirmed
        f.afterPrepare = { [unowned f] _ in f.focus = user }
        await #expect(throws: StageSwitchError.interrupted) { try await activate(groups[1], engine, f) }
        let journal = try readJournal(profile), earlier = try #require(journal.pending)
        #expect(earlier.entries.map(\.action) == [.show, .focus] && earlier.entries.allSatisfy { $0.after != nil })
        #expect(earlier.yieldedFocus == user && journal.owned == [held] && f.windows[held.hidden.window] == held.hidden)
        #expect(journal.lastWithdrawnHide?.group == groups[0].id && f.effects.count == 3)
        try await engine.release()
        #expect(f.focus == user && f.effects.count == 4 && f.effects.last?.1 == held.hidden.window && f.closes == 1)
    }

    @Test func changedDurableTransactionCannotBeClearedByAnOtherwiseValidWithdrawal() async throws {
        let (profile, store, engine, f, groups) = try setup()
        defer { try? FileManager.default.removeItem(at: profile) }
        try await bind(engine, f, qualification(.corner))
        let replacement = UUID(), user = try #require(f.windows.keys.first { $0.number == 4 })
        f.withdrawal = .confirmed
        f.afterPrepare = { [unowned f] _ in
            f.focus = user
            do {
                var newer = try readJournal(profile)
                newer.pending?.intent = replacement
                try JSONEncoder().encode(newer).write(to: profile.appendingPathComponent("stage-visibility-v1.json"), options: .atomic)
            } catch { Issue.record(error) }
        }
        await #expect(throws: StageSwitchError.recoveryRequired) { try await activate(groups[0], engine, f) }
        let onDisk = try readJournal(profile)
        #expect(f.withdrawalAttempts.count == 1 && f.withdrawn.count == 1 && f.effects.isEmpty)
        #expect(onDisk.lastWithdrawnHide == nil && onDisk.pending?.intent == replacement && onDisk.pending?.entries.count == 1)
        #expect(try StageGroupCoordinator(store: store, profile: profile).requiresRecovery)
    }

    @Test func withdrawalAfterLostReadDoesNotInventAUserFocusForPreviousEffects() async throws {
        let (profile, _, engine, f, groups) = try setup()
        defer { try? FileManager.default.removeItem(at: profile) }
        try await bind(engine, f, qualification(.corner))
        f.withdrawal = .confirmed
        f.afterPrepare = { [unowned f] _ in f.nextReadFails = true }
        await #expect(throws: StageSwitchError.interrupted) { try await activate(groups[1], engine, f) }
        let journal = try readJournal(profile), earlier = try #require(journal.pending)
        #expect(journal.lastWithdrawnHide != nil && earlier.entries.map(\.action) == [.focus] && earlier.yieldedFocus == nil)
        await #expect(throws: StageSwitchError.recoveryRequired) { try await engine.release() }
        #expect(f.effects.isEmpty && f.ordinaryEffects == [.focus] && f.closes == 0)
    }

    private func readJournal(_ profile: URL) throws -> StageGroupCoordinator.Ledger {
        let file = profile.appendingPathComponent("stage-visibility-v1.json")
        return try JSONDecoder().decode(StageGroupCoordinator.Ledger.self, from: Data(contentsOf: file))
    }
    private enum ReturnInterruption: CaseIterable { case none, bystanderMoved, newSelection, finalReplyLost }

    @Test(arguments: ReturnInterruption.allCases)
    private func failedRetirementReturnsOnlyTheMeasuredWindow(_ interruption: ReturnInterruption) async throws {
        let (profile, store, engine, f, groups) = try setup(2)
        defer { try? FileManager.default.removeItem(at: profile) }
        try await bind(engine, f, qualification(.corner))
        let target = try #require(f.windows.keys.first { $0.number == 2 })
        let bystander = try #require(f.windows.keys.first { $0.number == 3 })
        let current = try #require(groups.first { $0.members[0].windowHint == f.focus })
        let baseline = f.windows, originalFocus = f.focus
        var intentIsCurrent = true
        f.measuredHide = target.number
        f.failReturnConfirmation = interruption == .finalReplyLost
        if interruption == .bystanderMoved {
            f.secondBystanderRead = { [unowned f] in
                f.windows[bystander]?.frame = .init(x:470, y:40, width:380, height:260)
            }
        }
        f.beforeMeasuredReturn = {
            let journal = try readJournal(profile)
            let row = try #require(journal.pending?.entries.last)
            let undo = try #require(row.measuredReturnIntent)
            #expect(row.before.window == target && row.after == nil && undo != row.intent && undo != journal.pending?.intent)
            #expect(journal.lastLiveCornerReturn == nil)
            if interruption == .newSelection { intentIsCurrent = false }
        }
        await #expect(throws: (any Error).self) {
            try await engine.activate(current.id, member:current.members[0].id, in:f.scope,
                                      consent:true, current:{ intentIsCurrent })
        }
        let written = interruption == .none || interruption == .finalReplyLost
        #expect(f.bystanderReads == 2 && f.measuredWrites.count == (written ? 1 : 0))
        #expect(f.effects.map(\.0) == (written ? [3, 5] : [3]) && f.effects.allSatisfy { $0.1 == target })
        #expect(f.ordinaryEffects.isEmpty && f.focus == originalFocus && store.activeGroup(in:f.scope) == nil)
        let journal = try readJournal(profile)
        if interruption == .none {
            #expect(journal.lastLiveCornerReturn?.measuredReturnIntent == f.measuredWrites.first)
            #expect(journal.pending == nil && f.windows == baseline)
            try await engine.release()
            #expect(!engine.coordinator.hasWindowAuthority)
        } else {
            let row = try #require(journal.pending?.entries.last)
            #expect(row.measuredReturnIntent != nil && row.after == nil && journal.lastLiveCornerReturn == nil)
            #expect(journal.pending?.verifiedDirectoryCommit == false)
            if written { #expect(f.windows == baseline) }
            await #expect(throws: (any Error).self) { try await engine.release() }
            #expect(f.measuredWrites.count == (written ? 1 : 0))
        }
    }

    @Test func fullGroupCycleUsesOnlyOneBackendAndRestoresBystandersUnchanged() async throws {
        let (p,store,engine,f,groups)=try setup()
        defer {try? FileManager.default.removeItem(at:p)}
        let originals=f.windows
        let old=qualification(.corner), next=qualification(.corner)
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

    @Test func unhealthyBackendYieldsOnlyAfterRecoveryAndPositiveClose() async throws {
        let (p, _, engine, original, groups) = try setup()
        defer { try? FileManager.default.removeItem(at: p) }
        let fast = qualification(.corner, metrics(3)), spare = qualification(.spaces, metrics(7))
        let records = [fast, spare]
        let before = original.windows
        try await bind(engine, original, fast)
        try await activate(groups[0], engine, original)
        let session = try #require(engine.session)
        original.workerHealthy = false
        await #expect(throws: StageSwitchError.unavailable) { try await session.checkHealth() }
        #expect(session.backendFailed)
        #expect(engine.preferredRecord([fast], in: environment) == nil)
        #expect(engine.preferredRecord(records, in: environment) == nil)
        original.zeroLeases = false
        var allocations = 0
        await #expect(throws: StageSwitchError.recoveryRequired) {
            _ = try await engine.configure(for: environment, records: records, exclusive: { true }) { _ in allocations += 1; return nil }
        }
        #expect(allocations == 0 && engine.session === session && original.windows == before)
        original.zeroLeases = true
        let ok = try await engine.configure(for: environment, records: records, exclusive: { true }) { _ in
            allocations += 1
            return nil
        }
        #expect(!ok && allocations == 0 && original.closes == 1 && engine.session == nil)
        try await engine.release()
        #expect(engine.preferredRecord(records, in: environment) == nil)
    }

    @Test func externalFocusIsReadOnlyAndPermissionLossDoesNotDisqualifyTheBackend() async throws {
        let (p, _, engine, runtime, groups) = try setup()
        defer { try? FileManager.default.removeItem(at: p) }
        let q = qualification(.corner)
        try await bind(engine, runtime, q)
        try await activate(groups[0], engine, runtime)
        let session = try #require(engine.session)
        let active = try await session.read(runtime.scope)
        #expect(engine.coordinator.observesActiveGroup(active, owner: session.owner))
        let other = StageGroupScope(display: UUID(), nativeSpace: UUID())
        let otherWindow = NativeSpaceWindow(pid: 900, birth: 4000, number: 80)
        func sample(_ key: NativeSpaceWindow, _ scope: StageGroupScope?, _ states: [NativeSpaceWindow: StageWindowState]) -> StageWindowSample {
            .init(scope: active.scope, generation: active.generation, sequence: active.sequence, workArea: active.workArea,
                  windows: states, focus: key, nativeID: active.nativeID, foreignFocusScope: scope)
        }
        #expect(engine.coordinator.observesActiveGroup(sample(otherWindow, other, active.windows), owner: session.owner))
        #expect(!engine.coordinator.observesActiveGroup(sample(otherWindow, nil, active.windows), owner: session.owner))
        #expect(!engine.coordinator.observesActiveGroup(sample(otherWindow, active.scope, active.windows), owner: session.owner))
        #expect(!engine.coordinator.observesActiveGroup(sample(otherWindow, other, [:]), owner: session.owner))
        let user = try #require(runtime.windows.keys.first { $0.number == 4 })
        #expect(!engine.coordinator.observesActiveGroup(sample(user, other, active.windows), owner: session.owner))
        runtime.focus = user
        let external = try await session.read(runtime.scope)
        #expect(!engine.coordinator.observesActiveGroup(external, owner: session.owner))
        runtime.health = false
        await #expect(throws: StageSwitchError.unavailable) { try await session.checkHealth() }
        #expect(!session.backendFailed && engine.preferredRecord([q], in: environment) == q)
        try await engine.release()
        #expect(runtime.focus == user && runtime.windows.values.allSatisfy { $0.visibility == .visible })
    }

    @Test(arguments: [false, true])
    func obstructionAfterLastHideCannotCommitActivityAndRecoveryKeepsTheReviewedBackend(focusChanged: Bool) async throws {
        let (profile, store, engine, fixture, groups) = try setup()
        defer { try? FileManager.default.removeItem(at: profile) }
        let original = fixture.windows, reviewed = qualification(.corner)
        try await bind(engine, fixture, reviewed)
        fixture.obstructWhenRetired = true
        await #expect(throws: StageSwitchError.workAreaObstructed) { try await activate(groups[1], engine, fixture) }
        #expect(!fixture.visible.isEmpty && fixture.effects.contains { $0.0 == 3 })
        #expect(store.activeGroup(in: fixture.scope) == nil && engine.session?.isFrozen == true)
        #expect(try readJournal(profile).pending?.focusAtSurfaceInterruption == groups[1].members[0].windowHint)
        #expect(engine.session?.backendFailed == false && engine.holdsWindowDispatch)
        if focusChanged {
            let bystander = try #require(fixture.windows.keys.first { $0.number == 4 })
            fixture.focus = bystander
            await #expect(throws: StageSwitchError.recoveryRequired) { try await engine.release() }
            #expect(fixture.focus == bystander && engine.holdsWindowDispatch && fixture.closes == 0)
            #expect(try readJournal(profile).pending != nil)
        } else {
            try await engine.release()
            #expect(!engine.holdsWindowDispatch && fixture.closes == 1)
        }
        #expect(fixture.windows == original && fixture.visible.isEmpty)
        #expect(engine.preferredRecord([reviewed], in: environment) == reviewed)
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

    @Test(arguments: [true, false]) func confirmedTakeoverReleasesOnlyAfterTheOriginalRosterReturns(_ stable: Bool) async throws {
        let (profile, store, engine, f, groups) = try setup()
        defer { try? FileManager.default.removeItem(at: profile) }
        try await bind(engine, f, qualification(.corner))
        let before = f.windows, user = try #require(f.windows.keys.first { $0.number == 4 })
        f.beforeRead = { [unowned f] in
            if f.confirmed.count == 2 {
                f.focus = user
                f.beforeRead = nil
            }
        }
        await #expect(throws: StageSwitchError.interrupted) { try await activate(groups[0], engine, f) }
        #expect(engine.coordinator.requiresRecovery && f.focus == user)
        if !stable { f.windows[user]?.frame.x += 10 }
        if stable { try await engine.release() }
        else { await #expect(throws: StageSwitchError.recoveryRequired) { try await engine.release() } }
        #expect(f.effects.filter { $0.0 == 5 }.count == 2 && f.focus == user && f.ordinaryEffects.isEmpty)
        #expect(store.activeGroup(in: f.scope) == nil)
        let reopened = try StageGroupCoordinator(store: store, profile: profile)
        #expect(reopened.requiresRecovery == !stable && reopened.hasWindowAuthority == !stable)
        let bytes = try Data(contentsOf: profile.appendingPathComponent("stage-visibility-v1.json"))
        let ledger = try JSONDecoder().decode(StageGroupCoordinator.Ledger.self, from: bytes)
        if stable {
            let proof = try #require(ledger.lastInterruptedRelease)
            #expect(proof.focus == user && proof.firstSequence < proof.secondSequence && f.windows == before)
        } else {
            #expect(ledger.lastInterruptedRelease == nil && ledger.pending?.yieldedFocus == user && f.closes == 0)
        }
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
        try await bind(engine,f,qualification(.corner))
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

    @Test func guardianConfirmationFailureBlocksReplacementAndNeverRepeatsTheRustHide() async throws {
        let (p,store,engine,f,groups) = try setup()
        defer { try? FileManager.default.removeItem(at:p) }
        try await bind(engine,f,qualification(.corner))
        f.confirmationFailure = 2
        await #expect(throws:StageSwitchError.recoveryRequired) { try await activate(groups[0],engine,f) }
        #expect(f.effects.filter { $0.0 == 3 }.count == 1 && f.prepared.count == 1)
        let retained = try StageGroupCoordinator(store:store,profile:p)
        #expect(retained.hasWindowAuthority && retained.requiresRecovery && store.activeGroup(in:f.scope) == nil)
        var other = false
        await #expect(throws:StageSwitchError.recoveryRequired) {
            _ = try await engine.configure(for:environment,records:[qualification(.spaces)],exclusive:{true}) { _ in other = true; return nil }
        }
        #expect(!other && f.effects.filter { $0.0 == 3 }.count == 1)
    }

    @Test(arguments: [false, true])
    func lateGuardianReleaseUsesTheSameIntentWithoutRestoringTheWindowAgain(userMoved: Bool) async throws {
        let (profile, _, engine, fixture, groups) = try setup(2)
        defer { try? FileManager.default.removeItem(at: profile) }
        try await bind(engine, fixture, qualification(.corner))
        try await activate(groups[0], engine, fixture)
        fixture.holdReleaseReceipt = true
        await #expect(throws: StageSwitchError.recoveryRequired) { try await engine.release() }
        let release = try #require(try readJournal(profile).releases?.first)
        let target = release.owned.original.window
        let owner = try #require(engine.session?.owner)
        #expect(release.restored == true && release.intent == fixture.delayedRelease)
        #expect(engine.coordinator.awaitsFinalRelease(release.intent, from: owner))
        #expect(!engine.coordinator.awaitsFinalRelease(UUID(), from: owner))
        #expect(fixture.windows[target] == release.owned.original)
        let firstWrites = fixture.writeIntents, focus = fixture.focus

        if userMoved { fixture.windows[target]?.frame.x += 20 }
        fixture.holdReleaseReceipt = false
        if userMoved {
            await #expect(throws: StageSwitchError.recoveryRequired) { try await engine.release() }
            #expect(try readJournal(profile).releases?.first?.intent == release.intent)
            #expect(fixture.lateReleaseReads.isEmpty && fixture.closes == 0)
        } else {
            fixture.holdReleaseReceipt = true
            await #expect(throws: StageSwitchError.recoveryRequired) { try await engine.release() }
            #expect(try readJournal(profile).releases?.first?.intent == release.intent)
            fixture.holdReleaseReceipt = false
            try await engine.release()
            #expect(fixture.lateReleaseReads == [release.intent, release.intent] && fixture.closes == 1)
            let finished = try readJournal(profile)
            #expect(!engine.holdsWindowDispatch && finished.owner == nil)
            #expect(!engine.coordinator.awaitsFinalRelease(release.intent, from: owner))
        }
        #expect(fixture.writeIntents == firstWrites && fixture.focus == focus)
        #expect(fixture.effects.filter { $0.0 == 5 && $0.1 == target }.count == 1)
    }

    @Test func uncertainStartupRetainsOriginalWorkerUntilItCanClose() async throws {
        let (p,store,engine,f,groups) = try setup()
        defer { try? FileManager.default.removeItem(at:p) }
        f.canStart = false; f.zeroLeases = false
        try await bind(engine,f,qualification(.corner))
        await #expect(throws:StageSwitchError.incomplete) { try await activate(groups[0],engine,f) }
        let old = try StageGroupCoordinator(store:store,profile:p)
        #expect(old.retainedOwner == engine.session?.owner && old.hasWindowAuthority && !old.requiresRecovery)
        var attempted = false
        await #expect(throws:StageSwitchError.recoveryRequired) {
            _ = try await engine.configure(for:environment,records:[qualification(.corner)],exclusive:{true}) { _ in attempted = true; return nil }
        }
        #expect(!attempted && f.effects.isEmpty && f.prepared.isEmpty)
        f.zeroLeases = true
        try await engine.release()
        #expect(!engine.holdsWindowDispatch && f.closes == 1 && f.effects.isEmpty)
    }

    @Test func nextOwnedGroupIsActuallyRevealedBeforeRetiringLastVisibleGroup() async throws {
        let (p,_,engine,f,groups) = try setup(2)
        defer { try? FileManager.default.removeItem(at:p) }
        f.windows = f.windows.filter { $0.key.number <= 2 }
        try await bind(engine,f,qualification(.corner))
        for i in [0,1,0] { try await activate(groups[i],engine,f) }
        #expect(f.effects.map { $0.0 } == [3,4,3,4,3])
        #expect(f.visibleAfterMutation == [1,2,1,2,1])
    }

}
