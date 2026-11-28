import CryptoKit
import Darwin
import Foundation
import NearpaneCore

/// One serial read-only channel per overview feed. Only the child process and
/// its verified executable are reused; every request produces a new native sample.
/// Blocking pipe IO and waitpid run on this queue, never the MainActor or Swift's
/// cooperative executor. The queue is also the sole owner of the child PID.
final class DesktopOverviewReader: @unchecked Sendable {
    private let executable: URL, expectedHash: String
    private let idleTimeout: TimeInterval
    private let queue = DispatchQueue(label: "com.holdsnow.nearpane.overview-channel", qos: .utility)
    private var channel: OverviewReaderChannel?
    private var idleGeneration: UInt64 = 0

    init(executable: URL, expectedHash: String, idleTimeout: TimeInterval = 10) {
        self.executable = executable
        self.expectedHash = expectedHash
        self.idleTimeout = idleTimeout.isFinite && idleTimeout > 0 ? idleTimeout : 10
    }

    deinit {
        let child = channel
        queue.async { child?.stop() }
    }

    func read(_ request: DesktopReadRequest, timeout: Double = 3.8) async throws -> DesktopSnapshot {
        let payload = try JSONEncoder().encode(request)
        return try await perform(payload, session: request.session, timeout: timeout) {
            try DesktopReaderProcess.decode($0, request: request, overview: true)
        }
    }

    /// The raw framed transport is separately exercised with disposable test
    /// children. Product callers always use read(), including snapshot validation.
    func exchange(_ payload: Data, session: UUID, timeout: Double = 3.8,
                  didSpawn: (@Sendable (pid_t) -> Void)? = nil) async throws -> Data {
        try await perform(payload, session: session, timeout: timeout, didSpawn: didSpawn) { $0 }
    }

    private func perform<T: Sendable>(_ payload: Data, session: UUID, timeout: Double,
                                     didSpawn: (@Sendable (pid_t) -> Void)? = nil,
                                     decode: @escaping @Sendable (Data) throws -> T) async throws -> T {
        guard !payload.isEmpty, payload.count <= DesktopReaderFrame.requestLimit,
              timeout.isFinite, timeout > 0 else {
            traceFailure(ReaderFailure.invalidResponse, stage: "request-validation", session: session, requestBytes: payload.count)
            throw ReaderFailure.invalidResponse
        }
        let cancelled = OverviewReaderCancellation()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let priority = Task.currentPriority
        let qos: DispatchQoS = priority >= .userInitiated ? .userInitiated : .utility
        return try await withTaskCancellationHandler {
            do { try Task.checkCancellation() }
            catch {
                traceFailure(error, stage: "task-cancel-before-queue", session: session, requestBytes: payload.count)
                throw error
            }
            return try await withCheckedThrowingContinuation { continuation in
                queue.async(qos: qos, flags: .enforceQoS) { [self] in
                    var touchedChannel = false
                    var stage = "cancel-before-channel", completeFrameBytes: Int?
                    do {
                        try cancelled.check(deadline: deadline)
                        touchedChannel = true
                        idleGeneration &+= 1
                        stage = "replace-channel"
                        if channel?.session != session {
                            channel?.stop()
                            channel = nil
                        }
                        stage = "spawn"
                        if channel == nil {
                            channel = try OverviewReaderChannel(executable: executable,
                                expectedHash: expectedHash, session: session)
                            if let channel { didSpawn?(channel.pid) }
                        }
                        stage = "channel"
                        guard let child = channel else { throw ReaderFailure.unavailable }
                        stage = "exchange"
                        let bytes = try child.exchange(payload, deadline: deadline, cancelled: cancelled)
                        completeFrameBytes = bytes.count
                        stage = "cancel-after-exchange"
                        try cancelled.check(deadline: deadline)
                        // Invalid response identity/structure tears down this exact
                        // child before any subsequent request is admitted.
                        stage = "decode"
                        let value = try decode(bytes)
                        stage = "cancel-after-decode"
                        try cancelled.check(deadline: deadline)
                        retireWhenIdle(child)
                        continuation.resume(returning: value)
                    } catch {
                        let tracing = ProcessInfo.processInfo.environment["NP_SPACES_LAUNCH_TRACE"] != nil
                        let failedAt = tracing ? ProcessInfo.processInfo.systemUptime : nil
                        let childPID = touchedChannel ? channel?.pid : nil
                        let progress = touchedChannel ? channel?.exchangeProgress : nil
                        // A request cancelled while still queued never acquired
                        // this process and must not discard another read's warm child.
                        if touchedChannel { channel?.stop(); channel = nil }
                        traceFailure(error, stage: stage, session: session, requestBytes: payload.count,
                            touchedChannel: touchedChannel, childPID: childPID, progress: progress,
                            completeFrameBytes: completeFrameBytes, failedAt: failedAt)
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: { cancelled.cancel() }
    }

    private func traceFailure(_ error: Error, stage: String, session: UUID, requestBytes: Int,
                              touchedChannel: Bool = false, childPID: pid_t? = nil,
                              progress: OverviewReaderExchangeProgress? = nil,
                              completeFrameBytes: Int? = nil, failedAt: TimeInterval? = nil) {
        guard ProcessInfo.processInfo.environment["NP_SPACES_LAUNCH_TRACE"] != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let received = completeFrameBytes ?? progress?.payloadBytesRead ?? 0
        var facts: [String: Any] = ["event": "independentStageProduct", "phase": "desktop-overview-reader-failed",
            "failureStage": stage, "errorKind": overviewReaderErrorKind(error), "readSession": session.uuidString,
            "requestBytes": requestBytes, "touchedChannel": touchedChannel,
            "completeFrameReceived": completeFrameBytes != nil, "framePayloadReceived": received > 0,
            "framePayloadBytes": received, "failedUptime": failedAt ?? now, "uptime": now]
        if let childPID { facts["pid"] = childPID }
        if let progress {
            facts["exchangeStage"] = progress.stage
            facts["exchangeStageBytes"] = progress.stageBytes
            facts["frameHeaderBytes"] = progress.headerBytesRead
            if let expected = progress.expectedPayloadBytes { facts["expectedFramePayloadBytes"] = expected }
            if let operation = progress.ioOperation { facts["ioOperation"] = operation }
            if let result = progress.ioResult { facts["ioResult"] = result }
            if let error = progress.ioErrno { facts["ioErrno"] = error }
        }
        guard var bytes = try? JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys]) else { return }
        bytes.append(0x0a)
        try? FileHandle.standardError.write(contentsOf: bytes)
    }

    /// A retained feed may be disabled without being destroyed. Release its idle
    /// helper as well; generation and queue ownership prevent an old timer from
    /// terminating a later request or another child. No idle EOF is returned as a
    /// failed next read: the Host clears its channel before that read is admitted.
    private func retireWhenIdle(_ child: OverviewReaderChannel) {
        let generation = idleGeneration
        queue.asyncAfter(deadline: .now() + idleTimeout) { [weak self, weak child] in
            guard let self, let child, idleGeneration == generation, channel === child else { return }
            child.stop()
            channel = nil
        }
    }

    func close() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                idleGeneration &+= 1
                channel?.stop()
                channel = nil
                continuation.resume()
            }
        }
    }
}

/// Stable categories only: never log a payload, decoder coding path or localized error text.
private func overviewReaderErrorKind(_ error: Error) -> String {
    if error is CancellationError { return "CancellationError" }
    if let failure = error as? ReaderFailure {
        switch failure {
        case .unavailable: return "ReaderFailure.unavailable"
        case .invalidResponse: return "ReaderFailure.invalidResponse"
        case .timeout: return "ReaderFailure.timeout"
        case .outputLimit: return "ReaderFailure.outputLimit"
        }
    }
    if let failure = error as? DecodingError {
        switch failure {
        case .typeMismatch: return "DecodingError.typeMismatch"
        case .valueNotFound: return "DecodingError.valueNotFound"
        case .keyNotFound: return "DecodingError.keyNotFound"
        case .dataCorrupted: return "DecodingError.dataCorrupted"
        @unknown default: return "DecodingError.other"
        }
    }
    if error is DesktopReaderFrame.Failure { return "DesktopReaderFrame.invalidLength" }
    return "other"
}

private struct OverviewReaderExchangeProgress {
    var stage = "entry", stageBytes = 0
    var headerBytesRead = 0, payloadBytesRead = 0
    var expectedPayloadBytes: Int?
    var ioOperation: String?
    var ioResult: Int?, ioErrno: Int32?
}

private final class OverviewReaderCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check(deadline: TimeInterval) throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
        if ProcessInfo.processInfo.systemUptime >= deadline { throw ReaderFailure.timeout }
    }
}

/// Accessed only by DesktopOverviewReader.queue. A PID cannot be recycled before
/// this owner reaps it. No Process/terminationHandler races with waitpid here.
private final class OverviewReaderChannel: @unchecked Sendable {
    let session: UUID
    private(set) var pid: pid_t = 0
    private(set) var exchangeProgress: OverviewReaderExchangeProgress?
    private var input: Int32 = -1, output: Int32 = -1

    init(executable: URL, expectedHash: String, session: UUID) throws {
        self.session = session
        let bytes = try Data(contentsOf: executable, options: .mappedIfSafe)
        guard expectedHash.count == 64,
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == expectedHash else {
            throw ReaderFailure.unavailable
        }
        var toChild = [Int32](repeating: -1, count: 2), fromChild = [Int32](repeating: -1, count: 2)
        guard pipe(&toChild) == 0 else { throw ReaderFailure.unavailable }
        defer { for fd in toChild where fd >= 0 { Darwin.close(fd) } }
        guard pipe(&fromChild) == 0 else { throw ReaderFailure.unavailable }
        defer { for fd in fromChild where fd >= 0 { Darwin.close(fd) } }
        guard fcntl(toChild[1], F_SETFL, O_NONBLOCK) == 0,
              fcntl(fromChild[0], F_SETFL, O_NONBLOCK) == 0,
              fcntl(toChild[1], F_SETNOSIGPIPE, 1) == 0 else { throw ReaderFailure.unavailable }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw ReaderFailure.unavailable }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw ReaderFailure.unavailable }
        defer { posix_spawnattr_destroy(&attributes) }
        let tracing = ProcessInfo.processInfo.environment["NP_SPACES_LAUNCH_TRACE"] != nil
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawn_file_actions_adddup2(&actions, toChild[0], STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, fromChild[1], STDOUT_FILENO) == 0,
              (tracing ? posix_spawn_file_actions_adddup2(&actions, STDERR_FILENO, STDERR_FILENO) :
                posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)) == 0 else {
            throw ReaderFailure.unavailable
        }
        let path = executable.path(percentEncoded: false)
        var args: [UnsafeMutablePointer<CChar>?] = [path, "--window-overview-service"].map { $0.withCString { strdup($0) } }
        var environment: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/bin:/bin")]
        if tracing { environment.append(strdup("NP_SPACES_LAUNCH_TRACE=1")) }
        defer { args.forEach { free($0) }; environment.forEach { free($0) } }
        guard args.allSatisfy({ $0 != nil }), environment.allSatisfy({ $0 != nil }) else { throw ReaderFailure.unavailable }
        args.append(nil)
        environment.append(nil)
        var child: pid_t = 0
        guard posix_spawn(&child, path, &actions, &attributes, &args, &environment) == 0 else { throw ReaderFailure.unavailable }
        pid = child
        input = toChild[1]; toChild[1] = -1
        output = fromChild[0]; fromChild[0] = -1
        trace("desktop-overview-reader-started")
    }

    deinit { stop() }

    func exchange(_ payload: Data, deadline: TimeInterval, cancelled: OverviewReaderCancellation) throws -> Data {
        exchangeProgress = ProcessInfo.processInfo.environment["NP_SPACES_LAUNCH_TRACE"] != nil ? .init() : nil
        guard pid > 0 else { throw ReaderFailure.unavailable }
        exchangeStep("request-header-length")
        let requestHeader = try DesktopReaderFrame.header(length: payload.count, limit: DesktopReaderFrame.requestLimit)
        exchangeStep("request-header-write")
        try write(requestHeader, deadline: deadline, cancelled: cancelled)
        exchangeStep("request-body-write")
        try write(payload, deadline: deadline, cancelled: cancelled)
        exchangeStep("response-header-read")
        let header = try read(4, deadline: deadline, cancelled: cancelled)
        exchangeStep("response-header-length")
        let count = try DesktopReaderFrame.length(header, limit: DesktopReaderFrame.responseLimit)
        exchangeProgress?.expectedPayloadBytes = count
        exchangeStep("response-body-read")
        let bytes = try read(count, deadline: deadline, cancelled: cancelled, payload: true)
        exchangeStep("complete")
        return bytes
    }

    private func exchangeStep(_ stage: String) {
        exchangeProgress?.stage = stage
        exchangeProgress?.stageBytes = 0
    }

    private func recordIOFailure(_ operation: String, result: Int, error: Int32?) {
        exchangeProgress?.ioOperation = operation
        exchangeProgress?.ioResult = result
        exchangeProgress?.ioErrno = error
    }

    private func write(_ bytes: Data, deadline: TimeInterval, cancelled: OverviewReaderCancellation) throws {
        var offset = 0
        while offset < bytes.count {
            try cancelled.check(deadline: deadline)
            let size = bytes.withUnsafeBytes { raw in Darwin.write(input, raw.baseAddress!.advanced(by: offset), bytes.count - offset) }
            if size > 0 { offset += size; exchangeProgress?.stageBytes = offset }
            else if size < 0 && errno == EINTR { continue }
            else if size < 0 && errno == EAGAIN { try wait(input, events: Int16(POLLOUT), deadline: deadline, cancelled: cancelled) }
            else {
                let error = size < 0 ? errno : nil
                recordIOFailure("write", result: size, error: error)
                throw ReaderFailure.invalidResponse
            }
        }
    }

    private func read(_ count: Int, deadline: TimeInterval, cancelled: OverviewReaderCancellation, payload: Bool = false) throws -> Data {
        var bytes = Data(count: count), offset = 0
        while offset < count {
            try cancelled.check(deadline: deadline)
            let size = bytes.withUnsafeMutableBytes { raw in Darwin.read(output, raw.baseAddress!.advanced(by: offset), count - offset) }
            if size > 0 {
                offset += size
                exchangeProgress?.stageBytes = offset
                if payload { exchangeProgress?.payloadBytesRead = offset }
                else { exchangeProgress?.headerBytesRead = offset }
            }
            else if size < 0 && errno == EINTR { continue }
            else if size < 0 && errno == EAGAIN { try wait(output, events: Int16(POLLIN), deadline: deadline, cancelled: cancelled) }
            else {
                let error = size < 0 ? errno : nil
                recordIOFailure("read", result: size, error: error)
                throw ReaderFailure.invalidResponse
            }
        }
        return bytes
    }

    private func wait(_ fd: Int32, events: Int16, deadline: TimeInterval, cancelled: OverviewReaderCancellation) throws {
        try cancelled.check(deadline: deadline)
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        let delay = Int32(ceil(min(0.01, max(0, deadline - ProcessInfo.processInfo.systemUptime)) * 1000))
        if Darwin.poll(&descriptor, 1, delay) < 0 && errno != EINTR { throw ReaderFailure.invalidResponse }
    }

    func stop() {
        if input >= 0 { Darwin.close(input); input = -1 }
        if output >= 0 { Darwin.close(output); output = -1 }
        guard pid > 0 else { return }
        // This process owns no windows. Timeout/cancellation must not leave an AX
        // sample blocked forever or permit a late response to satisfy another call.
        let killed = kill(pid, SIGKILL)
        let killError = killed < 0 ? errno : 0
        var status: Int32 = 0
        var waited: pid_t = 0, waitError: Int32 = 0
        repeat {
            waited = waitpid(pid, &status, 0)
            waitError = waited < 0 ? errno : 0
        } while waited < 0 && waitError == EINTR
        trace("desktop-overview-reader-reaped", facts: ["killResult": killed,
            "killErrno": killed < 0 ? killError as Any : NSNull(),
            "waitpidResult": waited, "waitpidErrno": waited < 0 ? waitError as Any : NSNull(), "rawWaitStatus": status,
            "waitStatusAvailable": waited == pid])
        pid = 0
    }

    private func trace(_ phase: String, facts extra: [String: Any] = [:]) {
        guard ProcessInfo.processInfo.environment["NP_SPACES_LAUNCH_TRACE"] != nil else { return }
        var facts: [String: Any] = ["event": "independentStageProduct", "phase": phase,
            "pid": pid, "readSession": session.uuidString, "uptime": ProcessInfo.processInfo.systemUptime]
        for (key, value) in extra { facts[key] = value }
        guard var bytes = try? JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys]) else { return }
        bytes.append(0x0a)
        try? FileHandle.standardError.write(contentsOf: bytes)
    }
}
