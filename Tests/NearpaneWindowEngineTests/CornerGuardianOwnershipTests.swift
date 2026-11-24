import Foundation
import NearpaneCore
import Testing
@testable import NearpaneWindowEngine

struct CornerGuardianOwnershipTests {
    private typealias Report = CornerGuardianFixtureReport
    private let original = SurfaceRect(x: 130, y: 150, width: 280, height: 190)
    private let parked = SurfaceRect(x: -272, y: 670, width: 280, height: 190)

    private func acknowledged(sealed: Bool = true) -> Report.Handoff {
        var h = Report.Handoff(state: sealed ? "SEALED_ACKNOWLEDGED" : "PREPARED_ACKNOWLEDGED")
        h.guardianPID = 523
        h.guardianBirth = 1402
        h.sameChildGenerationNow = true
        h.originalGuardianImageLive = true
        h.originalIntent = UUID()
        h.member = UUID()
        h.lifetime = UUID()
        h.generation = UUID()
        h.epoch = 8
        h.original = original
        h.preparedAckUptimeNS = 180
        if sealed {
            h.parked = parked
            h.confirmedAckUptimeNS = 210
        }
        return h
    }

    @Test func matchingGeometryWithNoLiveHandoffCannotClaimRetention() {
        let r = Report.assess(.init(state: "NO_LIVE_HANDOFF_IN_THIS_HOST"), observedFrame: parked)
        #expect(r.status == "BLOCKED")
        #expect(r.retainedByGuardianAtPrepare == "NO_HANDOFF_BY_THIS_HOST")
        #expect(r.currentGuardianReference == "NO_HANDOFF_BY_THIS_HOST")
        #expect(r.currentWALRead == "NOT_RUN" && r.committedWALWitness == "NOT_OBSERVED")
        #expect(r.comparableParkedFrame == nil && !r.thisDiagnosticAuthorizesWrites)
    }

    @Test func coldOrAmbiguousIdentifiersCannotSubstituteForAcknowledgement() {
        for state in ["UNVERIFIED_FIXTURE", "AWAITING_PREPARE_ACK", "AMBIGUOUS_LIVE_HANDOFF", "LEASE_SCOPE_MISMATCH"] {
            var h = Report.Handoff(state: state)
            h.preparedAckUptimeNS = 180
            h.confirmedAckUptimeNS = 210
            let r = Report.assess(h, observedFrame: original)
            #expect(r.status == "UNKNOWN" && r.retainedByGuardianAtPrepare == "UNKNOWN")
            #expect(r.pendingWALWitness == "NOT_OBSERVED" && r.committedWALWitness == "NOT_OBSERVED")
        }
        var incomplete = acknowledged()
        incomplete.lifetime = nil
        #expect(Report.assess(incomplete, observedFrame: parked).pendingWALWitness == "NOT_OBSERVED")
    }

    @Test func pendingWitnessCannotAuthorizePostDeathWrite() {
        let r = Report.assess(acknowledged(sealed: false), observedFrame: original)
        #expect(r.retainedByGuardianAtPrepare == "CONFIRMED_AT_PREPARE_ACK")
        #expect(r.pendingWALWitness == "MATCHED_AT_PREPARE_ACK")
        #expect(r.committedWALWitness == "NOT_OBSERVED")
        #expect(r.reason == "noCommittedParkedPostimageAck" && r.status == "BLOCKED")
        #expect(!r.guardianCanWriteWhileOriginalHostLives)
    }

    @Test func staleGenerationOrChangedFrameBlocksEvenAfterRealAcknowledgements() {
        var replaced = acknowledged()
        replaced.sameChildGenerationNow = false
        let gone = Report.assess(replaced, observedFrame: parked)
        #expect(gone.reason == "survivingOriginalGuardianUnconfirmed" && gone.status == "BLOCKED")
        replaced.sameChildGenerationNow = true
        replaced.originalGuardianImageLive = false
        #expect(Report.assess(replaced, observedFrame: parked).status == "BLOCKED")
        let changed = Report.assess(acknowledged(), observedFrame: original)
        #expect(changed.comparableParkedFrame == false && changed.status == "BLOCKED")
        #expect(changed.committedWALWitness == "MATCHED_AT_CONFIRM_ACK")
    }

    @Test func authenticatedHistoryAndMatchingParkStillRequirePostDeathChecks() {
        let ready = Report.assess(acknowledged(), observedFrame: parked)
        #expect(ready.status == "UNKNOWN" && ready.comparableParkedFrame == true)
        #expect(ready.retainedByGuardianAtPrepare == "CONFIRMED_AT_PREPARE_ACK")
        #expect(ready.currentGuardianReference == "NOT_FRESHLY_OBSERVED")
        #expect(ready.committedWALWitness == "MATCHED_AT_CONFIRM_ACK" && ready.currentWALRead == "NOT_RUN")
        #expect(ready.crashAndRecovery == "NOT_RUN")
        #expect(!ready.thisDiagnosticAuthorizesWrites && !ready.guardianCanWriteWhileOriginalHostLives)
        let unmatched = Report.assess(acknowledged(), observedFrame: nil)
        #expect(unmatched.status == "UNKNOWN" && unmatched.comparableParkedFrame == nil)
    }

    @Test func outOfOrderPostimageCannotSealTheOriginalLease() {
        var h = acknowledged()
        h.confirmedAckUptimeNS = 179
        let r = Report.assess(h, observedFrame: parked)
        #expect(r.status == "BLOCKED" && r.committedWALWitness == "NOT_OBSERVED")
    }

    @Test @MainActor func invalidFixtureRegistrationReturnsBeforeNativeWindowQueries() throws {
        let r = Report.sample(pid: 0, birth: 0, number: 0, executable: URL(fileURLWithPath: "/"),
                              cdhash: "", scope: nil, nativeID: nil)
        #expect(r.hostReceiptCode == 1 && r.registered == nil && r.samples.isEmpty)
        #expect(r.hostObservation == "UNKNOWN" && r.handoff.state == "UNVERIFIED_FIXTURE")
        #expect(!r.hostTemporaryReferenceReleased && !r.guardianLaunchedByDiagnostic)
        #expect(r.windowWrites == 0 && r.globalEventsPosted == 0)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any])
        let recovery = try #require(json["recovery"] as? [String: Any])
        #expect(recovery["status"] as? String == "UNKNOWN")
        #expect(recovery["currentWALRead"] as? String == "NOT_RUN")
        #expect(recovery["normalWindowWriter"] as? String == "qualifiedOriginalHostOnly")
    }
}
