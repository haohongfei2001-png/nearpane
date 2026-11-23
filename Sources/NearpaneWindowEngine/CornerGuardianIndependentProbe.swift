import CNearpaneWindowEngine
import Darwin
import Foundation
import NearpaneCore

/// A bounded, read-only exchange with the installed Guardian. A command receipt can never be made from it.
package struct CornerGuardianIndependentProbe: Encodable, Sendable {
    struct Identity: Codable, Equatable, Sendable {
        let pid: Int32
        let birth: UInt64
        let cdhash: String
    }

    struct Evidence: Encodable, Sendable {
        let challenge: UUID
        let host, guardian: Identity
        let window: NativeSpaceWindow
        let fixtureHash: String
        let display, space: UUID?
        let nativeID: UInt64?
        let started, ended: UInt64
        let responsibleBefore, responsibleAfter: Int32
        let accessibilityBefore, accessibilityAfter: Bool
        let permissionQuery = "OBSERVED_TWICE_IN_SIGNED_GUARDIAN"
        let effectiveAccessibility, permissionAttribution: String
        let signatureAndGenerationClosed, heldInGuardian, temporaryObjectReleased, sameGeometry: Bool
        let matchesHostRegisteredGeometry: Bool?
        let temporaryRetention: String
        let receiptCode: Int32
        let samples: [GuardianSample]
    }

    struct GuardianSample: Encodable, Sendable {
        let uptimeNS: UInt64
        let signedFixture, kernelBirthMatches, exactCGOwner, onscreen, guardianAXTrusted: Bool
        let cornerAXAndMembershipStatus: UInt32?
        let heldGuardianReferenceMatches: Bool
        let ax, cg: SurfaceRect?

        init(_ read: CornerGuardianFixtureReport.Sample) {
            uptimeNS = read.uptimeNS
            signedFixture = read.registeredSignatureMatches
            kernelBirthMatches = read.kernelBirthMatches
            exactCGOwner = read.exactCGOwner
            onscreen = read.onscreen
            guardianAXTrusted = read.hostAXTrusted
            cornerAXAndMembershipStatus = read.cornerAXAndMembershipStatus
            heldGuardianReferenceMatches = read.heldHostReferenceMatches
            ax = read.ax
            cg = read.cg
        }
    }

    package let status: String
    let reason: String
    let childExit: Int32?
    let evidence: Evidence?
    let liveHandoffInHost: String
    let originalRetainedAtOperationalPrepare, pendingWALAtOperationalPrepare, committedWALAtOperationalConfirm: String
    private(set) var postExitWatchArmed = false
    let currentWALRead = "NOT_RUN"
    let committedOwnershipWatch = "NOT_STARTED_BY_DIAGNOSTIC"
    let park = "NOT_RUN"
    let mayPark = false
    let windowWrites = 0
    let permissionRequests = 0
    let crashRecovery = "NOT_RUN"

    private init(status: String, reason: String, childExit: Int32?, evidence: Evidence?, host: CornerGuardianFixtureReport) {
        self.status = status
        self.reason = reason
        self.childExit = childExit
        self.evidence = evidence
        liveHandoffInHost = host.handoff.state
        originalRetainedAtOperationalPrepare = host.recovery.retainedByGuardianAtPrepare
        pendingWALAtOperationalPrepare = host.recovery.pendingWALWitness
        committedWALAtOperationalConfirm = host.recovery.committedWALWitness
    }

    struct Request: Encodable, Sendable {
        let schema = 1
        let challenge: UUID
        let hostPID: Int32, hostBirth: UInt64, hostHash: String
        let childPID: Int32, childBirth: UInt64, childHash: String
        let window: NativeSpaceWindow, executable: String, fixtureHash: String
        let display, space: UUID?
        let nativeID: UInt64?
        let issued: UInt64
    }

    private struct Reply: Decodable, Sendable {
        let schema: Int, challenge: UUID
        let hostPID: Int32, hostBirth: UInt64, hostHash: String
        let childPID: Int32, childBirth: UInt64, childHash: String
        let window: NativeSpaceWindow, fixtureHash: String
        let display, space: UUID?
        let nativeID: UInt64?
        let started, ended: UInt64
        let responsibleBefore, responsibleAfter: Int32, axBefore, axAfter: Bool
        let receiptCode: Int32
        let observation: Data
    }

    private enum Failure: String, Error {
        case hostGenerationOrCanonicalPathChanged, signedChildGenerationUnavailable, boundedPipeFailure
        case signedReplyNotBoundToOriginalRequest, childOrHostChangedBeforeReturn, childExitUnconfirmed
    }

    static func permission(child: Int32, before: Bool, after: Bool, responsibleBefore: Int32,
                           responsibleAfter: Int32) -> (effective: String, attribution: String) {
        let effective = before == after ? (before ? "GRANTED_TO_CALLING_PROCESS" : "DENIED_TO_CALLING_PROCESS") : "CHANGED"
        let attribution: String
        if responsibleBefore <= 0 || responsibleBefore != responsibleAfter { attribution = "UNKNOWN" }
        else if responsibleBefore == child { attribution = "GUARDIAN_IS_RESPONSIBLE_PROCESS" }
        else { attribution = "ANOTHER_PROCESS_IS_RESPONSIBLE" }
        return (effective, attribution)
    }

    static func temporaryRetention(code: Int32, signature: Bool, scope: Bool, permission: String, attribution: String,
                                   attempted: Bool, held: Bool, released: Bool, sameGeometry: Bool, samplesMatch: Bool) -> String {
        if permission == "DENIED_TO_CALLING_PROCESS" { return "BLOCKED_GUARDIAN_AX_DENIED" }
        if attribution == "UNKNOWN" {
            return attempted ? "UNKNOWN_ATTRIBUTION_CHANGED_DURING_READ" : "NOT_ATTEMPTED_WITH_UNCERTAIN_ATTRIBUTION"
        }
        if attribution == "ANOTHER_PROCESS_IS_RESPONSIBLE" && !attempted {
            return "NOT_ATTEMPTED_WITH_UNCERTAIN_ATTRIBUTION"
        }
        if !scope { return "NOT_ATTEMPTED_WITHOUT_ORDINARY_SCOPE" }
        if code == 0 && signature && permission == "GRANTED_TO_CALLING_PROCESS" &&
            held && released && sameGeometry && samplesMatch {
            return attribution == "GUARDIAN_IS_RESPONSIBLE_PROCESS" ? "ORIGINAL_OBJECT_OBSERVED_TWICE_THEN_RELEASED" :
                "ORIGINAL_OBJECT_READ_DURING_PARENT_GRANT"
        }
        return "UNKNOWN"
    }

    @MainActor package static func sample(host: CornerGuardianFixtureReport, executable: URL, observeParentExit: UUID? = nil) async -> Self {
        let handoff = host.handoff.state
        guard host.hostPID == getpid(), let birth = host.hostBirth, let window = host.registered,
              let hash = host.registeredCDHash, host.hostReceiptCode == 0, host.samples.count == 2,
              host.samples.allSatisfy({ $0.registeredSignatureMatches && $0.kernelBirthMatches && $0.exactCGOwner }) else {
            return .init(status: "BLOCKED", reason: "hostDidNotConfirmExactlyOneRegisteredFixtureWindow",
                         childExit: nil, evidence: nil, host: host)
        }
        guard CornerGuardianClient.signedHelper() else {
            return .init(status: "BLOCKED", reason: "installedSignedGuardianOrCanonicalParentUnavailable",
                         childExit: nil, evidence: nil, host: host)
        }
        let ordinary = host.sampledScope, native = host.nativeID
        return await Task.detached {
            do {
                let (evidence, armed) = try exchange(window: window, executable: executable, fixtureHash: hash, hostBirth: birth,
                                            scope: ordinary, native: native, registeredFrame: host.samples.last?.cg, observeParentExit: observeParentExit)
                let reason: String
                if evidence.effectiveAccessibility == "DENIED_TO_CALLING_PROCESS" {
                    reason = "guardianAccessibilityDenied"
                } else if evidence.permissionAttribution != "GUARDIAN_IS_RESPONSIBLE_PROCESS" {
                    reason = "independentGuardianGrantUnconfirmed"
                } else if evidence.temporaryRetention != "ORIGINAL_OBJECT_OBSERVED_TWICE_THEN_RELEASED" {
                    reason = "ordinaryScopeOrIndependentOriginalObjectUnconfirmed"
                } else if evidence.matchesHostRegisteredGeometry != true {
                    reason = "currentGeometryDoesNotConfirmOriginalHostRegistration"
                } else {
                    reason = handoff == "NO_LIVE_HANDOFF_IN_THIS_HOST"
                        ? "noOperationalWALOrRetainedRecoveryLease" : "diagnosticHandleReleasedOperationalLeaseRemainsSeparate"
                }
                var result = Self(status: "BLOCKED", reason: reason, childExit: armed ? nil : 0, evidence: evidence, host: host)
                result.postExitWatchArmed = armed
                return result
            } catch {
                return Self(status: "UNKNOWN", reason: (error as? Failure)?.rawValue ?? "authenticatedReadbackUnavailable",
                            childExit: nil, evidence: nil, host: host)
            }
        }.value
    }

    private static func exchange(window: NativeSpaceWindow, executable: URL, fixtureHash: String, hostBirth: UInt64,
                                 scope: StageGroupScope?, native: UInt64?, registeredFrame: SurfaceRect?, observeParentExit: UUID?) throws -> (Evidence, Bool) {
        let helper = CornerGuardianClient.helper, pid = getpid()
        let image = try OrdinaryProcessImage.read(pid)
        let hostHash = try digest(pid)
        guard image.executable.path == "/Applications/Nearpane.app/Contents/MacOS/NearpaneHost",
              image.launch == hostBirth else { throw Failure.hostGenerationOrCanonicalPathChanged }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = helper
        process.arguments = [observeParentExit == nil ? "--inspect-registered-fixture" : "--inspect-fixture-after-host-exit"]
        process.environment = [:]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let writer = input.fileHandleForWriting
        let reader = output.fileHandleForReading
        guard fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw Failure.boundedPipeFailure }
        try process.run()
        defer { try? writer.close(); try? reader.close() }
        let child = process.processIdentifier
        let childImage = try OrdinaryProcessImage.read(child)
        let childHash = try digest(child)
        guard let childBirth = CornerGuardianClient.childGeneration(child), childImage.launch == childBirth,
              childImage.executable.path == helper.path else { throw Failure.signedChildGenerationUnavailable }
        let validScope = scope != nil && (native ?? 0) > 0
        let request = Request(challenge: observeParentExit ?? UUID(), hostPID: pid, hostBirth: hostBirth, hostHash: hostHash,
                              childPID: child, childBirth: childBirth, childHash: childHash, window: window,
                              executable: executable.path, fixtureHash: fixtureHash, display: validScope ? scope?.display : nil,
                              space: validScope ? scope?.nativeSpace : nil, nativeID: validScope ? native : nil,
                              issued: DispatchTime.now().uptimeNanoseconds)
        let payload = try JSONEncoder().encode(request)
        guard payload.count > 0 && payload.count < 4000 else { throw Failure.boundedPipeFailure }
        var size = UInt32(payload.count).bigEndian
        try writer.write(contentsOf: withUnsafeBytes(of: &size) { Data($0) } + payload)
        let data = try readLine(reader.fileDescriptor, until: request.issued + 6_000_000_000)
        let evidence = try decode(data, for: request, registeredFrame: registeredFrame)
        guard process.isRunning, CornerGuardianClient.childGeneration(child) == childBirth,
              try OrdinaryProcessImage.read(child) == childImage, try digest(child) == childHash,
              try OrdinaryProcessImage.read(pid) == image, try digest(pid) == hostHash else {
            throw Failure.childOrHostChangedBeforeReturn
        }
        // A watch owns a read-only AX reference and a NOTE_EXIT observation. It never owns a recovery lease.
        let canWatch = observeParentExit != nil && evidence.matchesHostRegisteredGeometry == true &&
            ["ORIGINAL_OBJECT_OBSERVED_TWICE_THEN_RELEASED", "ORIGINAL_OBJECT_READ_DURING_PARENT_GRANT"].contains(evidence.temporaryRetention)
        try writer.write(contentsOf: Data(canWatch ? "W".utf8 : "Q".utf8))
        if canWatch {
            let reply = try readLine(reader.fileDescriptor, until: DispatchTime.now().uptimeNanoseconds + 2_000_000_000)
            if reply == Data("ARMED".utf8) { return (evidence, true) }
            guard reply == Data("REFUSED".utf8) else { throw Failure.boundedPipeFailure }
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while process.isRunning && DispatchTime.now().uptimeNanoseconds < deadline { usleep(5_000) }
        guard !process.isRunning, process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw Failure.childExitUnconfirmed
        }
        return (evidence, false)
    }

    private static func digest(_ pid: Int32) throws -> String {
        try OrdinaryProcessImage.signingDigest(pid).map { String(format: "%02x", $0) }.joined()
    }

    private static func readLine(_ fd: Int32, until: UInt64) throws -> Data {
        var answer = Data(), bytes = [UInt8](repeating: 0, count: 2048)
        while answer.count <= 4000 {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < until else { throw Failure.boundedPipeFailure }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, Int32((until - now) / 1_000_000 + 1))
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0, p.revents & Int16(POLLIN) != 0 else { throw Failure.boundedPipeFailure }
            let count = read(fd, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0, answer.count + count <= 4001 else { throw Failure.boundedPipeFailure }
            answer.append(contentsOf: bytes.prefix(count))
            if let end = answer.firstIndex(of: 10) {
                guard end + 1 == answer.endIndex else { throw Failure.boundedPipeFailure }
                return Data(answer[..<end])
            }
        }
        throw Failure.boundedPipeFailure
    }

    static func decode(_ data: Data, for q: Request, registeredFrame: SurfaceRect?,
                       now: UInt64 = DispatchTime.now().uptimeNanoseconds) throws -> Evidence {
        let r = try JSONDecoder().decode(Reply.self, from: data)
        guard r.schema == 1, r.challenge == q.challenge, r.hostPID == q.hostPID, r.hostBirth == q.hostBirth,
              r.hostHash == q.hostHash, r.childPID == q.childPID, r.childBirth == q.childBirth, r.childHash == q.childHash,
              r.window == q.window, r.fixtureHash == q.fixtureHash, r.display == q.display, r.space == q.space, r.nativeID == q.nativeID,
              r.started >= q.issued, r.ended >= r.started, r.ended - q.issued <= 6_000_000_000,
              r.ended <= now,
              r.observation.count == MemoryLayout<NPGuardianFixtureObservation>.size else {
            throw Failure.signedReplyNotBoundToOriginalRequest
        }
        let obs = r.observation.withUnsafeBytes { $0.loadUnaligned(as: NPGuardianFixtureObservation.self) }
        guard obs.size == UInt32(r.observation.count), obs.version == 1 else { throw Failure.signedReplyNotBoundToOriginalRequest }
        let raw = [obs.first, obs.second].filter { $0.uptime_ns > 0 }.map(CornerGuardianFixtureReport.Sample.init)
        guard raw.allSatisfy({ $0.uptimeNS >= r.started && $0.uptimeNS <= r.ended }) else {
            throw Failure.signedReplyNotBoundToOriginalRequest
        }
        let exact = raw.count == 2 && raw[0].uptimeNS < raw[1].uptimeNS &&
            raw.allSatisfy { $0.registeredSignatureMatches && $0.kernelBirthMatches && $0.exactCGOwner &&
                $0.onscreen && $0.hostAXTrusted && $0.cornerAXAndMembershipStatus == 0 &&
                $0.ax != nil && $0.cg != nil && $0.heldHostReferenceMatches }
        let matchesRegistration = registeredFrame.flatMap { original -> Bool? in
            let frames = raw.compactMap(\.cg)
            guard frames.count == 2 else { return nil }
            return frames.allSatisfy { CornerGuardianFixtureReport.sameFrame($0, original) }
        }
        let permission = permission(child: r.childPID, before: r.axBefore, after: r.axAfter,
                                    responsibleBefore: r.responsibleBefore, responsibleAfter: r.responsibleAfter)
        let held = obs.held_in_caller == 1, released = obs.released == 1, same = obs.same_geometry == 1
        let attempted = raw.contains { $0.cornerAXAndMembershipStatus != nil }
        if !r.axBefore || ![r.childPID, r.hostPID].contains(r.responsibleBefore) || r.nativeID == nil {
            guard !attempted, !held, !released else { throw Failure.signedReplyNotBoundToOriginalRequest }
        }
        let status = temporaryRetention(code: r.receiptCode, signature: obs.signatures_closed == 1, scope: r.nativeID != nil,
                                        permission: permission.effective, attribution: permission.attribution, attempted: attempted, held: held,
                                        released: released, sameGeometry: same, samplesMatch: exact)
        return Evidence(challenge: r.challenge, host: .init(pid: r.hostPID, birth: r.hostBirth, cdhash: r.hostHash),
                        guardian: .init(pid: r.childPID, birth: r.childBirth, cdhash: r.childHash), window: r.window,
                        fixtureHash: r.fixtureHash, display: r.display, space: r.space, nativeID: r.nativeID,
                        started: r.started, ended: r.ended, responsibleBefore: r.responsibleBefore, responsibleAfter: r.responsibleAfter,
                        accessibilityBefore: r.axBefore, accessibilityAfter: r.axAfter,
                        effectiveAccessibility: permission.effective, permissionAttribution: permission.attribution,
                        signatureAndGenerationClosed: obs.signatures_closed == 1, heldInGuardian: held,
                        temporaryObjectReleased: released, sameGeometry: same, matchesHostRegisteredGeometry: matchesRegistration,
                        temporaryRetention: status,
                        receiptCode: r.receiptCode, samples: raw.map(GuardianSample.init))
    }
}
