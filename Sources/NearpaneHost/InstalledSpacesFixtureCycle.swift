import CNearpaneWindowEngine
import Foundation

/// Called only by the explicitly selected, private, installed-Host fixture handshake.
/// No PID, Space, geometry, target path, or signing hash can be supplied.
enum InstalledSpacesFixtureCycle {
    private static let refusals: [UInt32: String] = [
        0: "none", 1: "exactInstalledDeveloperIDHostRequired", 2: "exactBuildArchitectureAndSIPRequired",
        3: "existingHostAccessibilityRequired", 4: "sameUnlockedConsoleAndSingleDisplayRequired",
        5: "sameNoncePrivateRegistrationAndOwnerRequired", 7: "exactLiveAndDiskSignedFixtureRequired",
        8: "uniqueRetainedOrdinaryAXAndCGGeometryRequired", 9: "originalExternalForegroundChangedOrUnreadable",
        10: "physicalInputChanged", 11: "alreadyClaimedOrUnwritableNonce", 12: "existingUnresolvedExperiment",
        13: "fixtureDeadlineStopAbortOrObservationDeadline", 17: "systemReadOrTransportUncertain",
        18: "priorUnreconciledOrAlreadyUsedDurableJournal", 19: "durableJournalWriteOrSyncUnverified",
    ]
    private static let reasons = [
        "ready", "disabled", "exactBuildUnavailable", "reviewedSymbolsUnavailable", "connectionChangedOrUnreadable",
        "topologyChangedOrUnreadable", "identityChangedOrUnreadable", "exclusiveBidirectionalMembershipUnavailable",
        "ordinaryActiveScopeUnavailable", "originalAXBindingUnavailable", "ownershipMissing", "conflictingEvidence",
        "capacity", "operationRefused", "deliveryOrReadbackUnconfirmed", "parkingNotEmpty", "stale",
        "independentReadbackUnavailable", "priorRestoreRequired", "ownCanaryRequired", "verifiedFixtureTrial",
        "classicRoute", "bridgedRoute", "showVerified", "hideVerified", "cleanupUnverified", "health",
        "launchPassed", "probeClosed", "probeFocus",
    ]

    private static func observe(_ challenge: UUID, ownPanelOnly: Bool) -> Data {
        var proof = NPInstalledSpacesReceipt()
        proof.size = UInt32(MemoryLayout<NPInstalledSpacesReceipt>.size)
        proof.version = 1
        var bytes = challenge.uuid
        let transport = withUnsafeBytes(of: &bytes) {
            let nonce = $0.bindMemory(to: UInt8.self).baseAddress
            return ownPanelOnly ? np_spaces_installed_canary(nonce, &proof) : np_spaces_installed_fixture_cycle(nonce, &proof)
        }
        let phases = ["unused", "admission", "initialMembership", "hostCanary", "ordinaryWindowHide",
                      "ordinaryWindowReturnAndCleanup", "completed"]
        let states = ["PASS", "FAIL", "UNKNOWN", "BLOCKED", "TIMEOUT", "CANCELLED"]
        func name(_ entries: [String], _ value: UInt32) -> String {
            entries.indices.contains(Int(value)) ? entries[Int(value)] : "unknown"
        }
        func publicVisibility(_ n: UInt32) -> Any {
            n <= 1 ? (n == 1) as Any : NSNull()
        }
        func dispatches(_ create: UInt32, _ hide: UInt32, _ show: UInt32, _ destroy: UInt32) -> [String: UInt32] {
            ["create": create, "hide": hide, "return": show, "destroy": destroy]
        }
        let r = proof
        let reached = r.admission
        let checks: [String: Bool] = [
            "installedHostSignatureAndPath": reached & 1 != 0, "exact26A428AndSIP": reached & 2 != 0,
            "existingHostAccessibility": reached & 4 != 0, "sameConsoleAndDisplay": reached & 8 != 0,
            "sameNonceRegistrationOwnerAndDeadline": reached & 16 != 0, "pinnedLiveAndDiskFixture": reached & 32 != 0,
            "originalOrdinaryAXAndCGGeometry": reached & 64 != 0, "externalFocusAndHIDRecorded": reached & 128 != 0,
            "durableOneUseClaim": reached & 256 != 0,
        ]
        let canary: [String: Any] = [
            "owner": "installedHostPrivateNonactivatingPanel", "pid": r.host_pid, "window": r.canary_window,
            "originalSpace": r.home_id,
            "observedRegistration": r.canary_created == 1, "parkingID": r.canary_space,
            "restored": r.canary_restored == 1, "closed": r.canary_closed == 1, "parkingGone": r.canary_space_gone == 1,
            "dispatchAttempts": dispatches(r.canary_creates, r.canary_hides, r.canary_shows, r.canary_destroys),
        ]
        let document: [String: Any] = [
            "owner": "separatePinnedSignedRegularTransparentFixture", "pid": r.fixture_pid, "birth": r.fixture_birth,
            "window": r.fixture_window, "homeID": r.home_id, "parkingID": r.fixture_space,
            "originalCGAndAXFrame": [r.original_frame.0, r.original_frame.1, r.original_frame.2, r.original_frame.3],
            "initialIndependentReads": r.before_proofs, "parkedIndependentReads": r.parked_proofs,
            "returnedIndependentReads": r.returned_proofs,
            "cgOnScreenInitial": publicVisibility(r.before_onscreen), "cgOnScreenParked": publicVisibility(r.parked_onscreen),
            "cgOnScreenReturned": publicVisibility(r.returned_onscreen),
            "dispatchAttempts": dispatches(r.fixture_creates, r.fixture_hides, r.fixture_shows, r.fixture_destroys),
        ]
        let row: [String: Any] = [
            "schema": 1, "challenge": challenge.uuidString.lowercased(), "transport": transport,
            "status": transport == 0 ? name(states, r.status) : "UNKNOWN",
            "phase": name(phases, r.phase), "refusal": refusals[r.refusal] ?? "unrecognizedAdmissionCode",
            "reason": r.detail >= 200 ? name(reasons, r.detail - 200) : "noEngineResult",
            "engineDetail": r.detail, "admission": checks, "canary": canary,
            "trial": ownPanelOnly ? "ownPanelOnly" : "ownPanelAndEnrolledWindow",
            "fixture": ownPanelOnly ? ["status": "NOT_RUN", "dispatchAttempts": dispatches(r.fixture_creates, r.fixture_hides, r.fixture_shows, r.fixture_destroys)] : document,
            "endInventoryAndFocusReads": r.final_proofs, "heldWindows": r.held_windows, "heldSpaces": r.held_spaces,
            "canaryUnresolved": r.outstanding_canary != 0, "safeToRollback": transport == 0 && r.safe_to_rollback == 1,
            "durableJournalDirectory": "login-account/Library/Application Support/Nearpane-Spaces-Verification",
            "route": "bridgedOnly", "postedInput": 0, "permissionRequests": 0, "productionQualified": false,
        ]
        return (try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])) ?? Data()
    }

    @MainActor static func read(challenge: UUID, ownPanelOnly: Bool) async -> [String: Any] {
        // Release the main actor so its existing AppKit canary can perform bounded callbacks.
        let data = await Task.detached { observe(challenge, ownPanelOnly: ownPanelOnly) }.value
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ??
            ["schema": 1, "status": "UNKNOWN", "reason": "invalidNativeReceipt", "safeToRollback": false]
    }
}
