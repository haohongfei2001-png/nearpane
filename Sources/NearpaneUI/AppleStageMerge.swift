import AppKit
import ApplicationServices
import Darwin
import CryptoKit
import Security
import NearpaneCore
import NearpaneWindowEngine

/// The R4 drop supplies exact source and destination window identities. Apple changes its own stages.
@MainActor enum AppleStageMerge {
    typealias Members = Set<DesktopWindowKey>
    struct Observation {
        let timestamp: UInt64
        let settled: Bool
        let current: Members
        /// Complete, independently read WindowManager AX strip items; never inferred from card positions.
        let strip: [Members]
        let point: AppleStageMergePoint?
    }
    enum Failure: Error, Equatable { case unqualified, interrupted, unavailable, unconfirmed, busy }
    private static var dispatching = false

    // The signed product pins an independent QA key and receipt ID. A detached
    // receipt can bind the final CDHash without embedding that hash in its own image.
    private static let admission: StageWindowEngineAttestation.Pin? = nil
    private struct Qualification: Decodable {
        let version: Int, route, build, source, hostCDHash: String, evidence: UUID
        let physicalNativeMerge, exactReceiver, unrelatedStagesPreserved, releasedInput: Bool
    }
    static var isQualified: Bool {
        guard let pin = admission,
              let revision = Bundle.main.object(forInfoDictionaryKey: "NearpaneSourceRevision") as? String,
              Bundle.main.bundleIdentifier == "com.holdsnow.nearpane.alpha",
              Bundle.main.bundleURL.resolvingSymlinksInPath().path == "/Applications/Nearpane.app",
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let hash = try? OrdinaryProcessImage.signingDigest(getpid()) else { return false }
        let url = support.appendingPathComponent("Nearpane/StageEngineEvidence")
            .appendingPathComponent(pin.evidence.uuidString + ".json")
        guard (try? ProfileLease.checkPath(url)) != nil else { return false }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var fileInfo = stat()
        guard fstat(fd, &fileInfo) == 0, fileInfo.st_mode & S_IFMT == S_IFREG, (1...98_304).contains(fileInfo.st_size),
              let data = try? file.read(upToCount: 98_305), data.count == fileInfo.st_size,
              let envelope = try? JSONDecoder().decode(StageWindowEngineAttestation.Envelope.self, from: data),
              envelope.version == 1, envelope.payload.count <= 65_536,
              let key = try? P256.Signing.PublicKey(derRepresentation: pin.publicKeyDER),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: envelope.signature),
              key.isValidSignature(signature, for: envelope.payload),
              let receipt = try? JSONDecoder().decode(Qualification.self, from: envelope.payload),
              receipt.version == 1, receipt.route == "apple.native-strip-merge", receipt.evidence == pin.evidence,
              receipt.physicalNativeMerge, receipt.exactReceiver, receipt.unrelatedStagesPreserved, receipt.releasedInput,
              receipt.source == revision, receipt.hostCDHash == hash.map({ String(format: "%02x", $0) }).joined(),
              let requirement = teamRequirement else { return false }
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, (2...128).contains(size) else { return false }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0,
              receipt.build == String(decoding: bytes.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
        else { return false }
        var running: SecCode?
        return SecCodeCopySelf([], &running) == errSecSuccess &&
            running.map { SecCodeCheckValidity($0, [], requirement) } == errSecSuccess
    }
    private static let teamRequirement: SecRequirement? = {
        var r: SecRequirement?
        let requirement = "anchor apple generic and identifier \"com.holdsnow.nearpane.alpha\" and certificate leaf[subject.OU] = \"ZB9D4T66QB\""
        return SecRequirementCreateWithString(requirement as CFString, [], &r) == errSecSuccess ? r : nil
    }()

    /// Scope and input generation are checked again by the caller on every asynchronous return.
    /// Readback cannot infer a transfer from focus or a successful event post.
    static func perform(source: Members, destination: Members, stillCurrent: @escaping @MainActor () -> Bool,
                        observe: @escaping @MainActor (Members, Members) async -> Observation?) async throws {
        guard isQualified else { throw Failure.unqualified }
        guard !dispatching else { throw Failure.busy }
        guard !source.isEmpty, !destination.isEmpty, source.isDisjoint(with: destination),
              source.count <= 32 else { throw Failure.unavailable }
        dispatching = true
        defer { dispatching = false }
        var remaining = source, active = destination
        var protectedStrip: Set<Members>?
        while !remaining.isEmpty {
            guard safe(stillCurrent) else { throw Failure.interrupted }
            guard let before = await observe(remaining, active), safe(stillCurrent), before.settled,
                  let point = before.point, point.timestamp == before.timestamp,
                  let target = remaining.first(where: { $0.number == point.window }),
                  within(before.timestamp, milliseconds: 400),
                  let rest = preserved(before, current: active, source: remaining),
                  protectedStrip == nil || protectedStrip == rest else { throw Failure.unavailable }
            protectedStrip = rest
            try await press(point, windows: Set(remaining.map(\.number)), stillCurrent: stillCurrent)
            let oldActive = active, oldSource = remaining
            remaining.remove(target)
            active.insert(target)
            let deadline = ContinuousClock.now.advanced(by: .seconds(4))
            var confirmed = 0
            var last = before.timestamp
            while confirmed < 2 {
                guard safe(stillCurrent) else { throw Failure.interrupted }
                guard ContinuousClock.now < deadline else { throw Failure.unconfirmed }
                try await Task.sleep(for: .milliseconds(80))
                guard let after = await observe(remaining, active), safe(stillCurrent),
                      after.timestamp > last else { throw Failure.unconfirmed }
                last = after.timestamp
                guard after.settled else { confirmed = 0; continue }
                if preserved(after, current: active, source: remaining) == rest {
                    confirmed += 1
                } else if preserved(after, current: oldActive, source: oldSource) == rest {
                    confirmed = 0
                } else { throw Failure.unconfirmed }
            }
        }
    }

    /// Returns the unaffected partition only when native memberships are disjoint and exact.
    static func preserved(_ observation: Observation, current: Members, source: Members) -> Set<Members>? {
        guard observation.current == current, observation.settled else { return nil }
        var covered = current
        var others = Set<Members>()
        var found = source.isEmpty
        for group in observation.strip {
            guard !group.isEmpty, covered.isDisjoint(with: group) else { return nil }
            covered.formUnion(group)
            if group == source { found = true } else { others.insert(group) }
        }
        return found ? others : nil
    }

    private static func within(_ time: UInt64, milliseconds: UInt64) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        return time <= now && now - time <= milliseconds * 1_000_000
    }
    private static func safe(_ current: @MainActor () -> Bool) -> Bool {
        current() && !Task.isCancelled && WindowContentPreview.sessionAvailable() &&
            StageManagerPreference.read() == true && NSEvent.pressedMouseButtons == 0
    }
    private static func press(_ point: AppleStageMergePoint, windows: Set<UInt32>,
                              stillCurrent: @escaping @MainActor () -> Bool) async throws {
        // Upstream post::shift_press. Flags on the mouse event alone may switch to
        // another stage. A real Shift press is owned and released for this click.
        let forbidden: CGEventFlags = [.maskControl, .maskCommand, .maskAlternate, .maskShift, .maskSecondaryFn]
        let moveTypes: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        func moves() -> [UInt32] { moveTypes.map { CGEventSource.counterForEventType(.hidSystemState, eventType: $0) } }
        guard safe(stillCurrent), CGPreflightPostEventAccess(), CGPreflightListenEventAccess(), AXIsProcessTrusted(),
              CGEventSource.flagsState(.hidSystemState).intersection(forbidden).isEmpty,
              CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown) >= 0.15,
              moveTypes.allSatisfy({ CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) >= 0.05 }),
              point.stillHits(windows), within(point.timestamp, milliseconds: 500),
              let origin = CGEvent(source: nil)?.location, let src = CGEventSource(stateID: .privateState),
              let shiftDown = CGEvent(keyboardEventSource: src, virtualKey: 56, keyDown: true),
              let shiftUp = CGEvent(keyboardEventSource: src, virtualKey: 56, keyDown: false),
              let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: point.location, mouseButton: .left),
              let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: point.location, mouseButton: .left)
        else { throw Failure.unavailable }
        let initialMoves = moves()
        let input = NativeSelectionPermit.inputCounters()
        shiftDown.flags = .maskShift
        shiftUp.flags = []
        down.flags = .maskShift
        up.flags = .maskShift
        guard safe(stillCurrent) else { throw Failure.interrupted }
        shiftDown.post(tap: .cghidEventTap)
        defer { shiftUp.post(tap: .cghidEventTap) }
        try await Task.sleep(for: .milliseconds(12))
        guard safe(stillCurrent), moves() == initialMoves, input == NativeSelectionPermit.inputCounters(),
              point.stillHits(windows), within(point.timestamp, milliseconds: 550), CGPreflightPostEventAccess(),
              CGEventSource.flagsState(.hidSystemState).intersection([.maskControl, .maskCommand, .maskAlternate]).isEmpty
        else { throw Failure.interrupted }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        // Queue processing may follow the post. Warp back only when the pointer actually
        // reached the posted coordinate and the user has not since moved it.
        let limit = ContinuousClock.now.advanced(by: .milliseconds(18))
        while ContinuousClock.now < limit, moves() == initialMoves {
            if let at = CGEvent(source: nil)?.location, hypot(at.x-point.location.x, at.y-point.location.y) <= 1.5 {
                if hypot(origin.x-point.location.x, origin.y-point.location.y) > 1.5 {
                    _ = CGWarpMouseCursorPosition(origin)
                }
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        try await Task.sleep(for: .milliseconds(12))
    }
}
