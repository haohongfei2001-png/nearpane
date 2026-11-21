import CryptoKit
import Foundation
import NearpaneCore
@testable import NearpaneUI
import Testing

@MainActor struct StageWindowEngineWitnessTests {
    @Test func windowOwnerKeepsMetadataReaderAliveAfterSidebarHides() async {
        actor Counter {
            private(set) var reads = 0
            func increment() { reads += 1 }
        }
        let counter = Counter()
        let feed = CurrentDesktopWindows(read: { _ in await counter.increment(); throw StageSwitchError.unavailable },
                                         sessionAvailable: { true }, fingerprint: { 0 })
        feed.observe(true)
        feed.observeStageOwnership(true)
        feed.observe(false)
        _ = await feed.readNow()
        #expect(await counter.reads > 0)
        // Snapshot the last issued reader request on the same actor as release. A reader already
        // submitted to the concurrent executor may enter its counter after ownership changes.
        let lastAuthorizedRequest = feed.revision
        feed.observeStageOwnership(false)
        _ = await feed.readNow()
        #expect(feed.revision == lastAuthorizedRequest)
    }
    let id = ManagedWindowID(pid:15,launch:23,number:3,element:UUID())
    let display = DisplayObservation(id:"A",frame:.init(width:1200,height:900),rotationDegrees:0,backingScale:1)
    let other = DisplayObservation(id:"B",frame:.init(x:1200,width:900,height:900),rotationDegrees:0,backingScale:1)
    func sample(_ frame: SurfaceRect, _ member: UInt64, visible: Bool, minimized: Bool = false) -> StageWindowPhysicalObservation {
        .init(id:id,frame:frame,membership:member,onscreen:visible,minimized:minimized,focus:nil)
    }
    @Test func hiddenRequiresSpecificConfirmedWorkerAndIndependentGeometryOrMembership() throws {
        let normal = SurfaceRect(x:20,y:20,width:500,height:350)
        let parked = SurfaceRect(x:-490,y:-345,width:495,height:350)
        let hidden = sample(parked,4,visible:true), inSlot = sample(normal,99,visible:false)
        let corner = StageWindowEngineWitness.VisibilityClaim(backend:.corner,frame:parked,member:4)
        let slot = StageWindowEngineWitness.VisibilityClaim(backend:.spaces,frame:normal,member:99)
        func read(_ o: StageWindowPhysicalObservation,_ claim:StageWindowEngineWitness.VisibilityClaim? = nil) throws -> StageWindowState.Visibility {
            try StageWindowEngineWitness.classify(o,claim:claim,home:4,display:display,displays:[display,other])
        }
        #expect(try read(sample(normal,4,visible:true)) == .visible)
        #expect(try read(sample(normal,4,visible:false,minimized:true)) == .minimized)
        #expect(try read(hidden,corner) == .parked)
        #expect(try read(inSlot,slot) == .stageSpace)
        #expect(throws:StageSwitchError.self) { try read(hidden) }
        #expect(throws:StageSwitchError.self) { try read(inSlot) }
        #expect(throws:StageSwitchError.self) { try read(sample(normal,99,visible:true),slot) }
        #expect(throws:StageSwitchError.self) { try read(sample(normal,99,visible:false,minimized:true),slot) }
        #expect(throws:StageSwitchError.self) { try read(sample(normal,4,visible:true),.init(backend:.corner,frame:normal,member:4)) }
        let across = SurfaceRect(x:1198,y:-345,width:495,height:350)
        #expect(throws:StageSwitchError.self) { try read(sample(across,4,visible:true),.init(backend:.corner,frame:across,member:4)) }
    }
    @Test func onlyNewNoncurrentIndependentlyOwnedRecordMayVaryDuringASwitch() {
        let a = SpaceRecord(id:"1",isCurrent:true,ordinaryUUID:UUID())
        let b = SpaceRecord(id:"2",isCurrent:false,ordinaryUUID:UUID())
        let slot = SpaceRecord(id:"55",isCurrent:false,ordinaryUUID:UUID())
        let screen = { (rows:[SpaceRecord]) in ManagedDisplayScope(id:"ds",displayID:"A",records:rows) }
        let base = [screen([a,b])]
        #expect(StageWindowEngineWitness.topology([screen([a,slot,b])],matches:base,allowing:[55],on:"A"))
        #expect(StageWindowEngineWitness.topology(base,matches:base,allowing:[55],on:"A"))
        #expect(!StageWindowEngineWitness.topology(base,matches:base,allowing:[2],on:"A"))
        #expect(!StageWindowEngineWitness.topology([screen([b,slot,a])],matches:base,allowing:[55],on:"A"))
        #expect(!StageWindowEngineWitness.topology([screen([a,slot])],matches:base,allowing:[55],on:"A"))
        #expect(!StageWindowEngineWitness.topology([screen([a,b,slot])],matches:base,allowing:[],on:"A"))
    }
    @Test func shutdownReturnsFalseForUnresolvedJournalAndTrueForNewIsolatedProfile() async throws {
        let p = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:p,withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:p) }
        let store = StageGroupStore(profile:p), new = StageWindowEngineHost(profile:p,store:StageGroupStore(profile:p))
        #expect(await new.prepareForShutdown())
        let journal = p.appendingPathComponent("stage-visibility-v1.json"), bytes = Data("unreadable-stage-ledger".utf8)
        try bytes.write(to:journal)
        let unknown = StageWindowEngineHost(profile:p,store:store)
        #expect(!(await unknown.prepareForShutdown()))
        #expect(try Data(contentsOf:journal) == bytes)
    }
    @Test func noPreferenceOrForgedSidecarCanReplacePinnedPhysicalSignerAndEvidenceID() throws {
        let key = P256.Signing.PrivateKey()
        let e = StageEngineEnvironment(osBuild:"26A428",engineRevision:String(repeating:"a",count:40),hostCDHash:String(repeating:"b",count:40),
            hardware:"fixture",topology:"display",windowClass:"ordinary-standard",sipEnabled:true)
        let q = StageEngineQualification(backend:.corner,environment:e,evidence:UUID(),checks:[.independentlyObserved:.pass])
        let data = try JSONEncoder().encode(q)
        let sig = try key.signature(for:data).derRepresentation
        let pin = StageWindowEngineAttestation.Pin(evidence:q.evidence,publicKeyDER:key.publicKey.derRepresentation)
        let good = try JSONEncoder().encode(StageWindowEngineAttestation.Envelope(version:1,payload:data,signature:sig))
        #expect(StageWindowEngineAttestation.verify(good,pin:pin) == q)
        #expect(!q.admits(e))
        #expect(StageWindowEngineAttestation.verify(data,pin:pin) == nil)
        #expect(StageWindowEngineAttestation.verify(good,pin:.init(evidence:UUID(),publicKeyDER:pin.publicKeyDER)) == nil)
        #expect(StageWindowEngineAttestation.verify(good,pin:.init(evidence:q.evidence,publicKeyDER:P256.Signing.PrivateKey().publicKey.derRepresentation)) == nil)
        let changed = try JSONEncoder().encode(StageWindowEngineAttestation.Envelope(version:1,payload:data+Data([32]),signature:sig))
        #expect(StageWindowEngineAttestation.verify(changed,pin:pin) == nil)
        #expect(StageWindowEngineHost.shipped.isEmpty)
    }
    @Test func geometryPermitIsBoundToItsExactCommandAndNeverGrantsReadbackOrOrdinaryWrite() {
        let request = OrdinaryWindowRequest(.stagePlace,pid:id.pid,launch:id.launch,bundle:"fixture",id:id,focusDeadline:5)
        let yes = NativeSpaceStepPermission(id:request.nonce,submittedSteps:1,proceed:true)
        #expect(yes.permitsFocus(request,after:1,now:3))
        #expect(!yes.permitsFocus(request,after:2,now:3))
        #expect(!yes.permitsFocus(request,after:1,now:6))
        for action in [OrdinaryWindowRequest.Action.stageRead,.write] {
            let other = OrdinaryWindowRequest(action,pid:id.pid,launch:id.launch,bundle:"fixture",id:id,focusDeadline:5)
            #expect(!NativeSpaceStepPermission(id:other.nonce,submittedSteps:0,proceed:true).permitsFocus(other,after:0,now:3))
        }
    }
}
