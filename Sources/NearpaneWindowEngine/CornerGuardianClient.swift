import Darwin
import Foundation
import NearpaneCore
import Security
import CNearpaneWindowEngine

/// One live, independently signed recovery witness per outstanding Corner hide.
/// A restarted client never turns persisted window numbers into an actionable lease.
@MainActor final class CornerGuardianClient {
    private enum Failure: Error { case unavailable, changedLease, pendingRecovery }
    private final class Lease {
        let original: NativeStageEngineRequest
        let epoch: UInt64
        let process: Process
        let writer, reader, directory: FileHandle
        var result: NativeStageEngineReceipt?
        var sealed = false
        var recoveryFrameOnly = false
        var measuredReturnIntent: UUID?
        var withdrawing = false
        var preparation: CornerPreparedReceipt?
        var preparedAt: UInt64?
        var confirmedAt: UInt64?
        var guardianBirth: UInt64?
        var imageWatch: FileHandle?
        private var terminalImageState: Int32?
        var releaseIntent: UUID?
        var releaseAcknowledged = false

        func imageState(birth: UInt64) -> Int32 {
            if let terminalImageState { return terminalImageState }
            guard let watch = imageWatch else { return Int32(NP_GUARDIAN_IMAGE_LOST) }
            let state = np_corner_guardian_image_state(watch.fileDescriptor, process.processIdentifier, birth)
            if state == NP_GUARDIAN_IMAGE_LOST || state == NP_GUARDIAN_IMAGE_EXITED {
                terminalImageState = state
                imageWatch = nil
            }
            return state
        }
        init(_ original: NativeStageEngineRequest, epoch: UInt64, process: Process, writer: FileHandle, reader: FileHandle, directory: FileHandle) {
            self.original = original
            self.epoch = epoch
            self.process = process
            self.writer = writer
            self.reader = reader
            self.directory = directory
        }
    }
    private let profile: URL
    private let releaseExited: @MainActor (UUID) -> Void
    private var leases: [NativeSpaceWindow: Lease] = [:]
    private static let clients = NSHashTable<CornerGuardianClient>.weakObjects()
    init(profile: URL, releaseExited: @escaping @MainActor (UUID) -> Void) {
        self.profile = profile
        self.releaseExited = releaseExited
        Self.clients.add(self)
    }

    nonisolated static let helper = URL(fileURLWithPath: "/Applications/Nearpane.app/Contents/Helpers/NearpaneCornerGuardian")
    private static let identifier = "com.holdsnow.nearpane.alpha.corner-guardian"

    static func signedHelper() -> Bool {
        guard Bundle.main.bundleURL.standardizedFileURL.path == "/Applications/Nearpane.app",
              Bundle.main.bundleIdentifier == "com.holdsnow.nearpane.alpha",
              helper.resolvingSymlinksInPath().path == helper.path else { return false }
        return verifiedCode(at: helper, identifier: identifier)
    }

    nonisolated static func verifiedCode(at url: URL, identifier: String) -> Bool {
        let rule = "anchor apple generic and identifier \"\(identifier)\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"ZB9D4T66QB\""
        var requirement: SecRequirement?, code: SecStaticCode?
        return SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess &&
            SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess &&
            code.map { SecStaticCodeCheckValidity($0, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess } == true
    }

    private func same(_ a: NativeStageEngineRequest, _ b: NativeStageEngineRequest) -> Bool {
        a.backend == b.backend && a.group == b.group && a.member == b.member && a.lifetime == b.lifetime &&
            a.generation == b.generation && a.scope == b.scope && a.window == b.window && a.nativeID == b.nativeID
    }

    private func groupDirectory() throws -> URL {
        let dir = profile.appendingPathComponent(".corner-guardians", isDirectory: true)
        if mkdir(dir.path, 0o700) != 0 && errno != EEXIST { throw Failure.unavailable }
        var info = stat()
        guard lstat(dir.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o777 == 0o700 else { throw Failure.unavailable }
        try ProfileLease.syncDirectory(profile)
        return dir
    }

    private static func frame(_ r: SurfaceRect) -> [Double] { [r.x, r.y, r.width, r.height] }

    private func exchange(_ data: Data, ack: UInt8, lease: Lease) async throws {
        let read = lease.reader, write = lease.writer
        try await Task.detached {
            guard data.count <= 8192 else { throw Failure.unavailable }
            try write.write(contentsOf: data)
            var p = pollfd(fd: read.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let end = ProcessInfo.processInfo.systemUptime + 5
            while true {
                let ms = Int32(max(0, (end - ProcessInfo.processInfo.systemUptime) * 1000))
                guard ms > 0 else { throw Failure.unavailable }
                let observed = poll(&p, 1, ms)
                if observed < 0 && errno == EINTR { continue }
                guard observed > 0, (try read.read(upToCount: 1)) == Data([ack]) else { throw Failure.unavailable }
                return
            }
        }.value
    }

    private func packet(_ fields: [String: Any]) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        guard payload.count <= 8000 else { throw Failure.unavailable }
        var count = UInt32(payload.count).bigEndian
        return withUnsafeBytes(of: &count) { Data($0) } + payload
    }

    func prepare(_ r: NativeStageEngineRequest, epoch: UInt64) async throws {
        guard r.backend == 1, r.operation == 3, epoch > 0, let w = r.window, let group = r.group,
              let member = r.member, let lifetime = r.lifetime, let generation = r.generation,
              let scope = r.scope, let original = r.frame, r.nativeID > 0,
              leases[w] == nil, leases.count < 32, Self.signedHelper() else { throw Failure.unavailable }
        let parent = try groupDirectory()
        let directory = parent.appendingPathComponent(r.intent.uuidString.lowercased(), isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else { throw Failure.pendingRecovery }
        try ProfileLease.syncDirectory(parent)
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unavailable }
        let heldDirectory = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let data = try packet(["phase": "prepare", "epoch": epoch, "intent": r.intent.uuidString, "group": group.uuidString,
            "member": member.uuidString, "generation": generation.uuidString, "lifetime": lifetime.uuidString,
            "display": scope.display.uuidString, "space": scope.nativeSpace.uuidString, "native": r.nativeID,
            "pid": w.pid, "birth": w.birth, "number": w.number, "frame": Self.frame(original)])
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = Self.helper
        process.arguments = ["--watch", directory.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] child in
            Task { @MainActor in
                guard let self, let lease = self.leases[w], lease.process === child,
                      let intent = lease.releaseIntent else { return }
                self.releaseExited(intent)
            }
        }
        let pipeFD = input.fileHandleForWriting.fileDescriptor
        let flags = fcntl(pipeFD, F_GETFL)
        guard flags >= 0, fcntl(pipeFD, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(pipeFD, F_SETNOSIGPIPE, 1) == 0 else { throw Failure.unavailable }
        try process.run()
        let lease = Lease(r, epoch: epoch, process: process, writer: input.fileHandleForWriting, reader: output.fileHandleForReading, directory: heldDirectory)
        let launchedBirth = Self.childGeneration(process.processIdentifier)
        leases[w] = lease
        do {
            guard let launchedBirth, launchedBirth > 0, process.isRunning else { throw Failure.unavailable }
            let fd = np_corner_open_guardian_peer(process.processIdentifier, launchedBirth)
            guard fd >= 0 else { throw Failure.unavailable }
            lease.imageWatch = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try await exchange(data, ack: 82, lease: lease)
            guard let hostBirth = Self.generation(getpid(), parent: nil),
                  let prepared = CornerPreparedReceipt.read(in: heldDirectory.fileDescriptor),
                  prepared.matches(r, epoch: epoch, host: getpid(), hostBirth: hostBirth,
                                   child: process.processIdentifier, childBirth: launchedBirth),
                  lease.imageState(birth: launchedBirth) == NP_GUARDIAN_IMAGE_LIVE else {
                throw Failure.changedLease
            }
            lease.preparation = prepared
            lease.guardianBirth = launchedBirth
            lease.preparedAt = DispatchTime.now().uptimeNanoseconds
        }
        catch {
            // prepare has not returned to the Host. No engine write can have been submitted for this intent.
            try? lease.writer.close()
            try? lease.reader.close()
            leases.removeValue(forKey: w)
            throw error
        }
    }

    func preparedPeer(for r: NativeStageEngineRequest, epoch: UInt64) throws -> CornerGuardianPeer {
        guard r.backend == 1, r.operation == 3, let w = r.window, let l = leases[w], same(l.original, r),
              l.original.intent == r.intent, l.original.frame == r.frame, l.original.target == r.target,
              l.epoch == epoch, l.preparedAt != nil, !l.withdrawing, !l.sealed, l.result == nil,
              let proof = l.preparation, CornerPreparedReceipt.read(in: l.directory.fileDescriptor) == proof,
              let birth = l.guardianBirth, l.imageState(birth: birth) == NP_GUARDIAN_IMAGE_LIVE else { throw Failure.pendingRecovery }
        let fd = fcntl(l.writer.fileDescriptor, F_DUPFD_CLOEXEC, 3)
        guard fd >= 0 else { throw Failure.unavailable }
        return CornerGuardianPeer(pid: l.process.processIdentifier, birth: birth,
                                  writer: FileHandle(fileDescriptor: fd, closeOnDealloc: true))
    }

    func checkLiveOwners() throws {
        for lease in leases.values {
            guard let birth = lease.guardianBirth, lease.imageState(birth: birth) == NP_GUARDIAN_IMAGE_LIVE else {
                throw Failure.pendingRecovery
            }
        }
    }

    private func motionFields(_ phase: String, _ raw: NativeStageEngineReceipt) -> [String: Any] {
        ["phase": phase, "intent": raw.intent.uuidString, "epoch": raw.epoch, "native": raw.nativeID,
         "status": raw.status, "flags": raw.flags, "owned": raw.owned, "frame": Self.frame(raw.frame)]
    }

    func observe(_ r: NativeStageEngineRequest, receipt: NativeStageEngineReceipt) async throws {
        guard r.operation == 3 else { return }
        guard let w = r.window, let l = leases[w], same(l.original, r), r.intent == l.original.intent,
              let birth = l.guardianBirth, l.imageState(birth: birth) == NP_GUARDIAN_IMAGE_LIVE,
              !l.sealed, !l.withdrawing, l.result == nil, receipt.intent == r.intent, receipt.epoch == l.epoch,
              receipt.owned > 0, receipt.nativeID == r.nativeID else {
            throw Failure.pendingRecovery
        }
        if CornerMeasuredFrameReceipt.isMeasurement(receipt) {
            l.result = receipt
            try await exchange(try packet(motionFields("observeRecoveryFrame", receipt)), ack: 77, lease: l)
            guard let prepared = l.preparation, let observed = CornerMeasuredFrameReceipt.read(in: l.directory.fileDescriptor),
                  observed.matches(receipt, prepared: prepared) else { throw Failure.pendingRecovery }
            try checkLiveOwners()
            l.recoveryFrameOnly = true
            return
        }
        guard receipt.status == NP_PASS, receipt.flags & 191 == 190,
              receipt.flags & UInt32(NP_CORNER_RECOVERY_FRAME) == 0 else { throw Failure.pendingRecovery }
        l.result = receipt
        try await exchange(try packet(motionFields("observePark", receipt)), ack: 79, lease: l)
        try checkLiveOwners()
    }

    func confirm(_ r: NativeStageEngineRequest, verifiedFrame: SurfaceRect) async throws {
        guard let w = r.window, let l = leases[w], same(l.original, r), l.original.intent == r.intent,
              let birth = l.guardianBirth, l.imageState(birth: birth) == NP_GUARDIAN_IMAGE_LIVE,
              !l.sealed, !l.withdrawing, !l.recoveryFrameOnly, let raw = l.result, raw.status == NP_PASS,
              zip(Self.frame(raw.frame), Self.frame(verifiedFrame)).allSatisfy({ $0.isFinite && $1.isFinite && abs($0 - $1) <= 0.75 }) else { throw Failure.pendingRecovery }
        var fields = motionFields("confirm", raw)
        fields["verified"] = Self.frame(verifiedFrame)
        let data = try packet(fields)
        try await exchange(data, ack: 80, lease: l)
        try checkLiveOwners()
        l.confirmedAt = DispatchTime.now().uptimeNanoseconds
        l.sealed = true
    }

    func armMeasuredReturn(_ r: NativeStageEngineRequest, landing: SurfaceRect, intent: UUID) async throws {
        guard let w = r.window, let l = leases[w], l.original.intent == r.intent, same(l.original, r),
              l.recoveryFrameOnly, !l.sealed, l.measuredReturnIntent == nil, l.result?.frame == landing,
              let birth = l.guardianBirth, l.imageState(birth: birth) == NP_GUARDIAN_IMAGE_LIVE,
              intent != r.intent else { throw Failure.pendingRecovery }
        l.measuredReturnIntent = intent
        let message = try packet(["phase": "returnMeasured", "intent": r.intent.uuidString, "undo": intent.uuidString])
        try await exchange(Data([66]) + message, ack: 66, lease: l)
        try checkLiveOwners()
    }

    func finishMeasuredReturn(_ r: NativeStageEngineRequest, owner: StageEngineOwner, intent: UUID) async throws {
        guard let w = r.window, let l = leases[w], same(l.original, r), l.original.intent == r.intent,
              l.recoveryFrameOnly, l.measuredReturnIntent == intent, !l.sealed, l.releaseIntent == nil,
              let birth = l.guardianBirth, l.imageState(birth: birth) == NP_GUARDIAN_IMAGE_LIVE,
              let prepared = l.preparation, let raw = l.result else { throw Failure.pendingRecovery }
        l.releaseIntent = intent
        do { try await exchange(Data([82]), ack: 82, lease: l); l.releaseAcknowledged = true }
        catch { /* Read the terminal evidence once. A missing acknowledgement cannot replay the setter. */ }
        let image = l.imageState(birth: birth)
        let normalExit = image == NP_GUARDIAN_IMAGE_EXITED && !l.process.isRunning && l.process.terminationReason == .exit &&
            [0, 4].contains(l.process.terminationStatus)
        guard (image == NP_GUARDIAN_IMAGE_LIVE || image == NP_GUARDIAN_IMAGE_EXITED), l.releaseAcknowledged || normalExit,
              let measured = CornerMeasuredFrameReceipt.read(in: l.directory.fileDescriptor), measured.matches(raw, prepared: prepared),
              let final = CornerGuardianRecord.final.read(CornerLiveMeasuredReturnReceipt.self, in: l.directory.fileDescriptor),
              final.matches(owner: owner, undo: intent, prepared: prepared, measured: measured)
        else { throw Failure.pendingRecovery }
        try? l.writer.close(); try? l.reader.close()
        leases.removeValue(forKey: w)
    }

    func disarm(_ r: NativeStageEngineRequest) async throws {
        guard [4, 5].contains(r.operation), let w = r.window, let l = leases[w], same(l.original, r), l.sealed,
              let birth = l.guardianBirth, l.preparation != nil, l.result != nil,
              l.releaseIntent == nil || l.releaseIntent == r.intent else {
            throw Failure.pendingRecovery
        }
        if l.releaseIntent == nil {
            guard l.imageState(birth: birth) == NP_GUARDIAN_IMAGE_LIVE else { throw Failure.pendingRecovery }
            l.releaseIntent = r.intent
            do {
                try await exchange(Data([68]), ack: 68, lease: l)
                l.releaseAcknowledged = true
            } catch {
                // The helper may already have verified the window and fsynced its final record.
                // Never resend a release or repeat the window operation after a lost acknowledgement.
            }
        }
        var image = l.imageState(birth: birth)
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(300))
        while !l.releaseAcknowledged || image == NP_GUARDIAN_IMAGE_UNAVAILABLE {
            if image == NP_GUARDIAN_IMAGE_LOST || (image == NP_GUARDIAN_IMAGE_EXITED && !l.process.isRunning) ||
                ContinuousClock.now >= deadline { break }
            try await Task.sleep(for: .milliseconds(15))
            image = l.imageState(birth: birth)
        }
        guard consumeFinalRelease(r) else { throw Failure.pendingRecovery }
    }

    /// The original lease pins the directory, Guardian process generation and one release intent.
    /// This read never sends another release byte or reaches the window executor.
    func consumeFinalRelease(_ r: NativeStageEngineRequest) -> Bool {
        guard [4, 5].contains(r.operation), let w = r.window, let l = leases[w], same(l.original, r), l.sealed,
              l.releaseIntent == r.intent, let birth = l.guardianBirth, let prepared = l.preparation,
              let parked = l.result else { return false }
        let image = l.imageState(birth: birth)
        let normalExitCode = image == NP_GUARDIAN_IMAGE_EXITED && !l.process.isRunning && l.process.terminationReason == .exit
            ? l.process.terminationStatus : nil
        guard let receipt = CornerLiveReleaseReceipt.read(in: l.directory.fileDescriptor),
              receipt.confirms(prepared, parked: parked, image: image, acknowledged: l.releaseAcknowledged,
                               normalExitCode: normalExitCode) else { return false }
        try? l.writer.close()
        try? l.reader.close()
        leases.removeValue(forKey: w)
        return true
    }

    /// No caller can obtain the positive result from an error, a cancelled ticket, or a cold WAL.
    func withdraw(_ r: NativeStageEngineRequest, epoch: UInt64, excludeTicket: () throws -> Void) async throws -> Bool {
        guard r.backend == 1, r.operation == 3, let w = r.window, let l = leases[w], same(l.original, r),
              l.original.intent == r.intent, l.original.frame == r.frame, l.original.target == r.target,
              l.epoch == epoch, !l.sealed, !l.withdrawing, l.result == nil, l.preparedAt != nil,
              let childBirth = l.guardianBirth, l.imageState(birth: childBirth) == NP_GUARDIAN_IMAGE_LIVE,
              let hostBirth = Self.generation(getpid(), parent: nil) else { return false }
        let data = try packet(["phase": "withdrawUnsubmitted", "intent": r.intent.uuidString, "epoch": epoch])
        try excludeTicket()
        l.withdrawing = true
        try await exchange(data, ack: 87, lease: l)
        guard let receipt = CornerWithdrawalReceipt.read(in: l.directory.fileDescriptor),
              let prepared = l.preparation, receipt.withdrawal == prepared.original,
              receipt.matches(r, epoch: epoch, host: getpid(), hostBirth: hostBirth,
                              child: l.process.processIdentifier, childBirth: childBirth) else { return false }
        try? l.writer.close()
        try? l.reader.close()
        leases.removeValue(forKey: w)
        return true
    }

    nonisolated static func childGeneration(_ pid: Int32) -> UInt64? { generation(pid, parent: getpid()) }
    nonisolated static func generationIsGone(_ pid: Int32, birth: UInt64) -> Bool {
        guard pid > 1, birth > 0 else { return false }
        if let current = generation(pid, parent: nil) { return current != birth }
        return kill(pid, 0) == -1 && errno == ESRCH
    }
    private nonisolated static func generation(_ pid: Int32, parent: Int32?) -> UInt64? {
        guard pid > 1 else { return nil }
        var b = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue: b))
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &b, size) == size, b.pbi_pid == UInt32(pid),
              parent.map({ b.pbi_ppid == UInt32($0) }) != false, b.pbi_uid == getuid(),
              b.pbi_start_tvsec > 0 else { return nil }
        return b.pbi_start_tvsec * 1_000_000 + b.pbi_start_tvusec
    }

    /// Private live client state only. An R/P acknowledgement attests what the actual Guardian checked then.
    /// A process-generation check alone never attests today's AX reference, target geometry or recovery grant.
    static func observedHandoff(for target: NativeSpaceWindow, scope: StageGroupScope?, nativeID: UInt64?)
        -> CornerGuardianFixtureReport.Handoff {
        let matches = clients.allObjects.compactMap { $0.leases[target] }
        guard matches.count == 1, let l = matches.first else {
            return .init(state: matches.isEmpty ? "NO_LIVE_HANDOFF_IN_THIS_HOST" : "AMBIGUOUS_LIVE_HANDOFF")
        }
        guard let scope, let nativeID, scope == l.original.scope, nativeID == l.original.nativeID else {
            return .init(state: "LEASE_SCOPE_MISMATCH")
        }
        let child = l.process.processIdentifier
        let generation = l.guardianBirth
        let same = generation != nil && l.process.isRunning && childGeneration(child) == generation
        var result = CornerGuardianFixtureReport.Handoff(state: l.sealed ? "SEALED_ACKNOWLEDGED" :
            l.recoveryFrameOnly ? "RECOVERY_FRAME_ACKNOWLEDGED" :
            l.preparedAt != nil ? "PREPARED_ACKNOWLEDGED" : "AWAITING_PREPARE_ACK")
        result.guardianPID = child
        result.guardianBirth = generation
        result.sameChildGenerationNow = same
        result.originalGuardianImageLive = generation.map { l.imageState(birth: $0) == NP_GUARDIAN_IMAGE_LIVE }
        result.originalIntent = l.original.intent
        result.member = l.original.member
        result.lifetime = l.original.lifetime
        result.generation = l.original.generation
        result.epoch = l.epoch
        result.preparedAckUptimeNS = l.preparedAt
        result.confirmedAckUptimeNS = l.confirmedAt
        result.original = l.original.frame
        result.parked = l.sealed ? l.result?.frame : nil
        return result
    }

    func finish() async throws {
        guard leases.isEmpty else { throw Failure.pendingRecovery }
    }
}
