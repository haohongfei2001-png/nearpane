import CNearpaneWindowEngine
import CryptoKit
import Darwin
import Foundation
import NearpaneCore
import Security

/// The worker remains the original native engine owner if the Host exits. Closing
/// either pipe starts release-only cleanup from its retained AX objects. There is
/// deliberately no same-process fallback and no reconstruction from saved IDs.
actor SpacesEngineWorker {
    nonisolated let acquisitionEpoch: UInt64 = 1
    private nonisolated let channel: SpacesWorkerChannel

    init?(profile: URL) {
        guard let channel = try? SpacesWorkerChannel(profile: profile) else { return nil }
        self.channel = channel
    }
    nonisolated func currentEpoch() throws -> UInt64 { try channel.currentEpoch() }
    nonisolated func revoke() { channel.revoke() }

    func launchSpaces(expectedEpoch: UInt64? = nil) async throws -> NativeStageEngineReceipt {
        try await submit(.init(backend: UInt32(NP_SPACES), operation: UInt32(NP_LAUNCH), intent: UUID()),
                         timeoutMilliseconds: 9_000, expectedEpoch: expectedEpoch)
    }
    func releaseSpaces(expectedEpoch: UInt64? = nil) async throws -> NativeStageEngineReceipt {
        try await submit(.init(backend: UInt32(NP_SPACES), operation: UInt32(NP_RELEASE_SPACES), intent: UUID()),
                         timeoutMilliseconds: 9_000, expectedEpoch: expectedEpoch)
    }
    func submit(_ input: NativeStageEngineRequest, timeoutMilliseconds: UInt32 = 1000,
                expectedEpoch: UInt64? = nil) async throws -> NativeStageEngineReceipt {
        try Task.checkCancellation()
        guard input.backend == NP_SPACES else { throw NativeStageEngineError.correlation }
        let epoch = try expectedEpoch ?? channel.currentEpoch()
        var raw = NativeStageWindowEngine.encode(input, timeout: timeoutMilliseconds, epoch: epoch)
        let payload = withUnsafeBytes(of: &raw) { Data($0) }, channel = channel
        let accepted = try await Task.detached {
            try channel.exchange(UInt32(NP_SW_SUBMIT), request: payload)
        }.value
        guard accepted.transport == NP_OK, accepted.ticket > 0 else {
            throw NativeStageEngineError.transport(accepted.transport)
        }
        let ticket = accepted.ticket
        return try await withTaskCancellationHandler {
            // A cancellation still consumes the native terminal receipt. If the
            // channel itself fails, the worker consumes it before releasing leases.
            while true {
                let response = try await Task.detached {
                    try channel.exchange(UInt32(NP_SW_POLL), ticket: ticket)
                }.value
                if response.transport == NP_PENDING {
                    await Task.detached { try? await Task.sleep(for: .milliseconds(2)) }.value
                    continue
                }
                guard response.transport == NP_OK else {
                    throw NativeStageEngineError.transport(response.transport)
                }
                let result = response.receipt
                guard result.intent == input.intent, result.epoch == epoch else {
                    channel.disconnect()
                    throw NativeStageEngineError.correlation
                }
                return result
            }
        } onCancel: { channel.cancel(ticket) }
    }
    func close() async -> Bool {
        let channel = channel
        do {
            let response = try await Task.detached { try channel.exchange(UInt32(NP_SW_CLOSE)) }.value
            guard response.transport == NP_OK else { return false }
            channel.finish()
            return true
        } catch {
            // Only this exact worker's clean exit can establish that its EOF
            // cleanup finished. Core separately reads every surviving window home.
            return await Task.detached { channel.waitForReleasedExit(seconds: 10) }.value
        }
    }
}

private struct SpacesWorkerResponse: Sendable {
    let transport: UInt32
    let ticket: UInt64
    let receipt: NativeStageEngineReceipt
}

/// Locks protect only bounded anonymous-pipe IO and the local revocation epoch.
/// Native work runs on the Rust worker, leaving both AppKit main loops responsive.
private final class SpacesWorkerChannel: @unchecked Sendable {
    private enum Failure: Error { case unavailable, protocolMismatch, channelLost }
    private let process: Process
    private let writer, reader, diagnostic: FileHandle
    private let exchangeLock = NSLock(), writeLock = NSLock(), stateLock = NSLock()
    private var epoch: UInt64 = 1, serial: UInt64 = 0
    private var ready = false, failed = false, closed = false

    init(profile: URL) throws {
        let bundle = Bundle.main, root = bundle.bundleURL.resolvingSymlinksInPath()
        let executable = root.appendingPathComponent("Contents/Helpers/NearpaneSpacesEngine")
        let host = root.appendingPathComponent("Contents/MacOS/NearpaneHost")
        guard bundle.executableURL?.resolvingSymlinksInPath() == host,
              executable.resolvingSymlinksInPath() == executable,
              let seal = bundle.object(forInfoDictionaryKey: "NearpaneSpacesEngineSHA256") as? String,
              seal.count == 64, let bytes = try? Data(contentsOf: executable, options: .mappedIfSafe),
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == seal,
              Self.signed(executable, identifier: "com.holdsnow.nearpane.spaces-engine")
        else { throw Failure.unavailable }
        var directory = stat()
        // The profile URL can be constructed before createDirectory(), without a
        // directory URL hint. Compare canonical paths, not that representation bit.
        guard profile.resolvingSymlinksInPath().path == profile.path,
              lstat(profile.path, &directory) == 0, directory.st_uid == getuid(),
              directory.st_mode & S_IFMT == S_IFDIR else { throw Failure.unavailable }
        let path = profile.appendingPathComponent("spaces-worker-" + UUID().uuidString.lowercased() + ".jsonl")
        let fd = open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unavailable }
        diagnostic = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let input = Pipe(), output = Pipe()
        writer = input.fileHandleForWriting; reader = output.fileHandleForReading
        process = Process()
        process.executableURL = executable; process.arguments = ["--stdio"]
        process.standardInput = input; process.standardOutput = output; process.standardError = diagnostic
        for endpoint in [writer, reader] {
            let descriptor = endpoint.fileDescriptor, flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
                  fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw Failure.unavailable }
        }
        guard fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw Failure.unavailable }
        try process.run()
        // These copies must not keep either direction artificially alive after exit.
        try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
    }
    deinit {
        // Do not terminate the child: it owns the only surviving native leases.
        try? writer.close(); try? reader.close(); try? diagnostic.close()
    }
    private static func signed(_ file: URL, identifier: String) -> Bool {
        var code: SecStaticCode?, requirement: SecRequirement?
        let rule = "identifier \"\(identifier)\""
        return SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess &&
            SecStaticCodeCreateWithPath(file as CFURL, [], &code) == errSecSuccess &&
            code.map { SecStaticCodeCheckValidity($0, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess } == true
    }
    func currentEpoch() throws -> UInt64 {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !failed, !closed, process.isRunning else { throw Failure.channelLost }
        return epoch
    }
    private func abort() {
        writeLock.lock(); defer { writeLock.unlock() }
        stateLock.lock(); failed = true; stateLock.unlock()
        try? writer.close() // EOF requests the same original owner's cleanup.
    }
    func disconnect() { abort() }
    func waitForReleasedExit(seconds: TimeInterval) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while true {
            stateLock.lock(); let wasClosed = closed, wasFailed = failed; stateLock.unlock()
            if wasClosed { return true }
            guard wasFailed else { return false }
            if !process.isRunning {
                guard process.terminationReason == .exit, process.terminationStatus == 0 else { return false }
                finish()
                return true
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
    func finish() {
        writeLock.lock(); defer { writeLock.unlock() }
        stateLock.lock(); closed = true; stateLock.unlock()
        try? writer.close(); try? reader.close()
    }
    func revoke() {
        stateLock.lock()
        guard !closed, !failed, epoch < UInt64.max else { stateLock.unlock(); return }
        epoch += 1
        stateLock.unlock()
        control(UInt32(NP_SW_REVOKE), ticket: 0)
    }
    func cancel(_ ticket: UInt64) { control(UInt32(NP_SW_CANCEL), ticket: ticket) }
    private func control(_ operation: UInt32, ticket: UInt64) {
        do { try send(packet(operation, serial: 0, ticket: ticket), seconds: 0.1) }
        catch { abort() }
    }
    private func packet(_ operation: UInt32, serial: UInt64, ticket: UInt64, request: Data? = nil) throws -> Data {
        var message = NPSpacesWorkerRequest()
        message.magic = UInt32(NP_SW_MAGIC); message.version = UInt32(NP_SW_VERSION)
        message.operation = operation; message.size = UInt32(MemoryLayout<NPSpacesWorkerRequest>.size)
        message.serial = serial; message.ticket = ticket
        if let request {
            guard request.count == MemoryLayout<NPRequest>.size else { throw Failure.protocolMismatch }
            message.request = request.withUnsafeBytes { $0.loadUnaligned(as: NPRequest.self) }
        }
        return withUnsafeBytes(of: &message) { Data($0) }
    }
    private func send(_ data: Data, seconds: TimeInterval) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        stateLock.lock(); let usable = !failed && !closed; stateLock.unlock()
        guard usable else { throw Failure.channelLost }
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(writer.fileDescriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written > 0 { offset += written; continue }
                if written < 0, errno == EINTR { continue }
                guard written < 0, errno == EAGAIN || errno == EWOULDBLOCK else { throw Failure.channelLost }
                try wait(writer.fileDescriptor, event: Int16(POLLOUT), deadline: deadline)
            }
        }
    }
    private func wait(_ fd: Int32, event: Int16, deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw Failure.channelLost }
            var descriptor = pollfd(fd: fd, events: event, revents: 0)
            let result = Darwin.poll(&descriptor, 1, Int32(min(5000, max(1, remaining * 1000))))
            if result < 0, errno == EINTR { continue }
            // POLLIN may accompany HUP: consume the final reply before observing EOF.
            if result > 0, descriptor.revents & event != 0 { return }
            throw Failure.channelLost
        }
    }
    private func receive() throws -> NPSpacesWorkerReply {
        var data = Data(count: MemoryLayout<NPSpacesWorkerReply>.size)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let received = Darwin.read(reader.fileDescriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if received > 0 { offset += received; continue }
                if received < 0, errno == EINTR { continue }
                guard received < 0, errno == EAGAIN || errno == EWOULDBLOCK else { throw Failure.channelLost }
                try wait(reader.fileDescriptor, event: Int16(POLLIN), deadline: deadline)
            }
        }
        let reply = data.withUnsafeBytes { $0.loadUnaligned(as: NPSpacesWorkerReply.self) }
        guard reply.magic == NP_SW_MAGIC, reply.version == NP_SW_VERSION, reply.size == data.count,
              reply.reserved == 0 else { throw Failure.protocolMismatch }
        return reply
    }
    func exchange(_ operation: UInt32, ticket: UInt64 = 0, request: Data? = nil) throws -> SpacesWorkerResponse {
        exchangeLock.lock(); defer { exchangeLock.unlock() }
        do {
            _ = try currentEpoch()
            if !ready {
                let hello = try receive()
                guard hello.operation == NP_SW_READY, hello.serial == 0, hello.ticket == 0,
                      hello.transport == NP_OK, hello.epoch == 1 else { throw Failure.protocolMismatch }
                ready = true
            }
            serial += 1
            try send(packet(operation, serial: serial, ticket: ticket, request: request), seconds: 1)
            let reply = try receive()
            guard reply.operation == operation, reply.serial == serial,
                  operation == NP_SW_SUBMIT || reply.ticket == ticket,
                  reply.epoch > 0 || operation == NP_SW_CLOSE && reply.transport == NP_OK
            else { throw Failure.protocolMismatch }
            stateLock.lock(); epoch = max(epoch, reply.epoch); stateLock.unlock()
            let r = reply.receipt
            if operation == NP_SW_POLL, reply.transport == NP_OK {
                guard r.size == MemoryLayout<NPReceipt>.size, r.version == NP_ENGINE_ABI else { throw Failure.protocolMismatch }
            }
            return .init(transport: reply.transport, ticket: reply.ticket,
                         receipt: .init(status: r.status, flags: r.flags, detail: r.detail, owned: r.owned,
                                        nativeID: r.native_id, epoch: r.epoch,
                                        frame: SurfaceRect(x: r.frame.x, y: r.frame.y, width: r.frame.width, height: r.frame.height),
                                        intent: UUID(uuid: r.intent)))
        } catch { abort(); throw error }
    }
}
