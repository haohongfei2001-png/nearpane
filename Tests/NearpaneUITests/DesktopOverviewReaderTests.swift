import CryptoKit
import Darwin
import Foundation
import Testing
import NearpaneCore
@testable import NearpaneUI

/// Exercise actual framed pipes and child lifetime without reading or writing a
/// user's windows. Compile the small native peer once, outside every read's
/// deadline; each test gets a private, hashed executable and marker directory.
struct DesktopOverviewReaderTests {
    private struct Fixture {
        let directory: URL, executable: URL, hash: String
        private static let compiledBytes = Task<Data, Error> {
            try await withCheckedThrowingContinuation { continuation in
                // Neither the compiler's startup nor waitUntilExit may occupy
                // the MainActor/cooperative executor or a transport read budget.
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try compile() })
                }
            }
        }

        private static func compile() throws -> Data {
            let output = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("nearpane-reader-compiler-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: output) }
            let executable = output.appendingPathComponent("reader")
            let log = output.appendingPathComponent("compiler.log")
            try Data().write(to: log)
            let diagnostics = try FileHandle(forWritingTo: log)
            defer { try? diagnostics.close() }
            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Fixtures/DesktopOverviewReaderFixture.c")
            let compiler = Process()
            compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            compiler.arguments = ["clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                                  source.path, "-o", executable.path]
            compiler.standardInput = FileHandle.nullDevice
            compiler.standardOutput = diagnostics
            compiler.standardError = diagnostics
            try compiler.run()
            compiler.waitUntilExit()
            guard compiler.terminationReason == .exit, compiler.terminationStatus == 0 else {
                let input = try FileHandle(forReadingFrom: log)
                defer { try? input.close() }
                let message = String(decoding: try input.read(upToCount: 8192) ?? Data(), as: UTF8.self)
                throw NSError(domain: "DesktopOverviewReaderFixture", code: Int(compiler.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: "Native reader fixture compilation failed: " + message])
            }
            return try Data(contentsOf: executable)
        }

        init() async throws {
            let bytes = try await Self.compiledBytes.value
            directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("nearpane-reader-test-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            executable = directory.appendingPathComponent("reader")
            try bytes.write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
        func clean() { try? FileManager.default.removeItem(at: directory) }
        func reader(idleTimeout: Double = 10) -> DesktopOverviewReader {
            .init(executable: executable, expectedHash: hash, idleTimeout: idleTimeout)
        }
    }
    private struct Reply: Decodable { let pid: pid_t, count: Int, value: Int? }
    private final class Observation<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value?
        func record(_ observed: Value) { lock.lock(); value = observed; lock.unlock() }
        func read() -> Value? { lock.lock(); defer { lock.unlock() }; return value }
    }
    private func request(_ action: String = "split", value: Int = 1) -> Data {
        Data("{\"action\":\"\(action)\",\"value\":\(value)}".utf8)
    }
    private func reply(_ bytes: Data) throws -> Reply { try JSONDecoder().decode(Reply.self, from: bytes) }
    private func isReaped(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        return waitpid(pid, &status, WNOHANG) == -1 && errno == ECHILD
    }

    @Test func repeatedRequestsReuseOneChildAndPreserveDistinctFragmentedReplies() async throws {
        let fixture = try await Fixture(); defer { fixture.clean() }
        let reader = fixture.reader(), session = UUID()
        let first = try reply(await reader.exchange(request(value: 11), session: session))
        let second = try reply(await reader.exchange(request(value: 22), session: session))
        #expect(first.pid == second.pid && first.count == 1 && second.count == 2)
        #expect(first.value == 11 && second.value == 22)
        await reader.close()
        #expect(isReaped(first.pid))
    }

    @Test func anotherFeedUsesANewChildAndRetiresThePreviousOne() async throws {
        let fixture = try await Fixture(); defer { fixture.clean() }
        let reader = fixture.reader()
        let first = try reply(await reader.exchange(request(), session: UUID()))
        let second = try reply(await reader.exchange(request(), session: UUID()))
        #expect(first.pid != second.pid && second.count == 1 && isReaped(first.pid))
        await reader.close()
    }

    @Test(arguments: ["oversize", "truncated"])
    func malformedFrameCannotBeConsumedByTheNextRequest(_ action: String) async throws {
        let fixture = try await Fixture(); defer { fixture.clean() }
        let reader = fixture.reader(), session = UUID(), spawned = Observation<pid_t>()
        await #expect(throws: (any Error).self) {
            try await reader.exchange(request(action), session: session, didSpawn: { spawned.record($0) })
        }
        let pid = try #require(spawned.read())
        #expect(isReaped(pid))
        let next = try reply(await reader.exchange(request(), session: session))
        #expect(next.pid != pid && next.count == 1)
        await reader.close()
    }

    @Test @MainActor func cancellationDoesNotBlockTheMainActorAndReapsItsExactChild() async throws {
        let fixture = try await Fixture(); defer { fixture.clean() }
        let reader = fixture.reader(), session = UUID(), spawned = Observation<pid_t>()
        let completed = Observation<ContinuousClock.Instant>()
        let payload = request("hang")
        let job = Task.detached {
            defer { completed.record(ContinuousClock.now) }
            return try await reader.exchange(payload, session: session, didSpawn: { spawned.record($0) })
        }
        defer { job.cancel() }
        let marker = fixture.directory.appendingPathComponent("hang-ready")
        let deadline = ContinuousClock.now + .seconds(2)
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(FileManager.default.fileExists(atPath: marker.path))
        let pid = try #require(spawned.read())
        let heartbeat = Task { @MainActor in completed.read() == nil }
        #expect(await heartbeat.value)
        let began = ContinuousClock.now
        job.cancel()
        await #expect(throws: CancellationError.self) { try await job.value }
        // Measure the request's actual completion, excluding any later wait for
        // unrelated tests to release the MainActor before this assertion runs.
        let finished = try #require(completed.read())
        #expect(finished - began < .seconds(1))
        #expect(isReaped(pid))
        let next = try reply(await reader.exchange(request(), session: session))
        #expect(next.pid != pid)
        await reader.close()
    }

    @Test func timeoutReapsChildAndDoesNotReturnAnyLateResponse() async throws {
        let fixture = try await Fixture(); defer { fixture.clean() }
        let reader = fixture.reader(), spawned = Observation<pid_t>(), session = UUID()
        await #expect(throws: (any Error).self) {
            try await reader.exchange(request("hang"), session: session, timeout: 0.2, didSpawn: { spawned.record($0) })
        }
        #expect(isReaped(try #require(spawned.read())))
        let next = try reply(await reader.exchange(request(), session: session))
        #expect(next.count == 1)
        await reader.close()
    }

    @Test func cancelledQueuedReadCannotRetireTheSuccessfulPredecessorsChild() async throws {
        let fixture = try await Fixture(); defer { fixture.clean() }
        let reader = fixture.reader(), session = UUID()
        let original = try reply(await reader.exchange(request(), session: session))
        let slowPayload = request("slow"), queuedPayload = request()
        let slow = Task { try await reader.exchange(slowPayload, session: session) }
        let marker = fixture.directory.appendingPathComponent("slow-ready")
        let deadline = ContinuousClock.now + .seconds(2)
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(FileManager.default.fileExists(atPath: marker.path))
        let queued = Task { try await reader.exchange(queuedPayload, session: session) }
        await Task.yield()
        queued.cancel()
        try Data().write(to: fixture.directory.appendingPathComponent("slow-release"))
        let completed = try reply(await slow.value)
        await #expect(throws: CancellationError.self) { try await queued.value }
        let next = try reply(await reader.exchange(request(), session: session))
        #expect(completed.pid == original.pid && next.pid == original.pid && next.count == 3)
        await reader.close()
    }

    @Test func unusedFeedReleasesItsChildAndTheNextReadStartsCleanly() async throws {
        let fixture = try await Fixture(); defer { fixture.clean() }
        let reader = fixture.reader(idleTimeout: 0.1), session = UUID()
        let first = try reply(await reader.exchange(request(), session: session))
        let deadline = ContinuousClock.now + .seconds(2)
        while kill(first.pid, 0) == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(isReaped(first.pid))
        let next = try reply(await reader.exchange(request(), session: session))
        #expect(next.pid != first.pid && next.count == 1)
        await reader.close()
    }

    @Test func invalidSnapshotInvalidatesTheChannelEvenWhenFramingIsCorrect() async throws {
        let fixture = try await Fixture(); defer { fixture.clean() }
        let reader = fixture.reader(), session = UUID()
        let original = try reply(await reader.exchange(request(), session: session))
        let input = DesktopReadRequest(session: session, revision: 1, parentPID: getpid(),
            fixtureWindows: nil, anchors: [], experimentalSpaces: false)
        await #expect(throws: (any Error).self) { try await reader.read(input) }
        #expect(isReaped(original.pid))
        let next = try reply(await reader.exchange(request(), session: session))
        #expect(next.pid != original.pid)
        await reader.close()
    }

    @Test func changedExecutableCannotStartANewReader() async throws {
        let fixture = try await Fixture(); defer { fixture.clean() }
        let reader = fixture.reader()
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fixture.executable)
        await #expect(throws: (any Error).self) { try await reader.exchange(request(), session: UUID()) }
        await reader.close()
    }
}
