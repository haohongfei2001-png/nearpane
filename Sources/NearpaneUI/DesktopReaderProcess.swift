import Foundation
import Darwin
import NearpaneCore

enum ReaderFailure: Error { case unavailable, invalidResponse, timeout, outputLimit }

/// One disposable read. The parent owns waitpid until reap, so cancellation can never signal a recycled PID.
enum DesktopReaderProcess {
    static func read(executable: URL, request: DesktopReadRequest, timeout: Double = 3.8) async throws -> DesktopSnapshot {
        let input = try JSONEncoder().encode(request)
        guard input.count <= 8192 else { throw ReaderFailure.invalidResponse }
        let job = Task.detached(priority: .utility) {
            try collect(executable: executable, argument: input.base64EncodedString(), timeout: timeout)
        }
        let bytes = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
        let snapshot = try JSONDecoder().decode(DesktopSnapshot.self, from: bytes)
        guard snapshot.isStructurallyValid, snapshot.sessionID == request.session, snapshot.revision == request.revision,
              snapshot.native?.population == (request.fixtureWindows == nil ? .workWindows : .markedFixture),
              request.experimentalSpaces || snapshot.native?.spaces == .disabled,
              snapshot.native?.rows.allSatisfy({ request.anchors.contains($0.anchor) }) == true else { throw ReaderFailure.invalidResponse }
        if let fixture = request.fixtureWindows {
            guard snapshot.windows.allSatisfy({ w in
                w.metadata.map { $0.pid == request.parentPID && fixture.contains($0.number) } == true
            }) else { throw ReaderFailure.invalidResponse }
        } else if snapshot.windows.contains(where: { $0.metadata?.pid == request.parentPID }) { throw ReaderFailure.invalidResponse }
        return snapshot
    }

    private static func collect(executable: URL, argument: String, timeout: Double) throws -> Data {
        try Task.checkCancellation()
        var fds = [Int32](repeating: -1, count: 2)
        guard pipe(&fds) == 0 else { throw ReaderFailure.unavailable }
        defer { close(fds[0]); if fds[1] >= 0 { close(fds[1]) } }
        guard fcntl(fds[0], F_SETFL, O_NONBLOCK) == 0 else { throw ReaderFailure.unavailable }
        var actions: posix_spawn_file_actions_t?, attrs: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw ReaderFailure.unavailable }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attrs) == 0 else { throw ReaderFailure.unavailable }
        defer { posix_spawnattr_destroy(&attrs) }
        guard posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO) == 0 else { throw ReaderFailure.unavailable }
        var args = [executable.path, "--read-encoded", argument].map { strdup($0) } + [nil]
        var env = [strdup("PATH=/usr/bin:/bin"), nil]
        defer { args.forEach { free($0) }; env.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, executable.path, &actions, &attrs, &args, &env) == 0 else { throw ReaderFailure.unavailable }
        close(fds[1]); fds[1] = -1
        var status: Int32 = 0, reaped = false, eof = false
        defer {
            if !reaped {
                kill(pid, SIGKILL)
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while !reaped || !eof {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ReaderFailure.timeout }
            let count = Darwin.read(fds[0], &buffer, buffer.count)
            if count > 0 {
                guard bytes.count + count <= 1_048_576 else { throw ReaderFailure.outputLimit }
                bytes.append(contentsOf: buffer.prefix(count))
            } else if count == 0 { eof = true }
            else if errno != EAGAIN && errno != EINTR { throw ReaderFailure.invalidResponse }
            if !reaped {
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid { reaped = true }
                if result < 0 && errno != EINTR {
                    if errno == ECHILD { reaped = true }
                    throw ReaderFailure.unavailable
                }
            }
            if count <= 0 && (!eof || !reaped) { usleep(12_000) }
        }
        guard status == 0 else { throw ReaderFailure.unavailable }
        return bytes
    }
}
