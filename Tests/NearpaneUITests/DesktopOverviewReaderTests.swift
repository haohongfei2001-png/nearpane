import CryptoKit
import Darwin
import Foundation
import Testing
import NearpaneCore
@testable import NearpaneUI

/// Exercise actual framed pipes and child lifetime without reading or writing a
/// user's windows. The fixture is a private, hashed Python executable.
struct DesktopOverviewReaderTests {
    private struct Fixture {
        let directory: URL, executable: URL, hash: String
        init() throws {
            directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("nearpane-reader-test-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            executable = directory.appendingPathComponent("reader")
            let bytes = Data(#"""
            #!/usr/bin/python3
            import json, os, struct, sys, time
            def exact(n):
                b = b''
                while len(b) < n:
                    x = os.read(0, n - len(b))
                    if not x: sys.exit(0)
                    b += x
                return b
            count = 0
            while True:
                size = struct.unpack('>I', exact(4))[0]
                request = json.loads(exact(size))
                count += 1
                action = request.get('action', 'invalid')
                if action == 'slow':
                    open(os.path.join(os.path.dirname(__file__), 'slow-ready'), 'w').close()
                    while not os.path.exists(os.path.join(os.path.dirname(__file__), 'slow-release')): time.sleep(0.005)
                if action == 'hang': time.sleep(30)
                if action == 'oversize':
                    os.write(1, struct.pack('>I', 1048577))
                    time.sleep(30)
                if action == 'truncated':
                    os.write(1, struct.pack('>I', 100) + b'{')
                    sys.exit(0)
                reply = json.dumps({'pid': os.getpid(), 'count': count, 'value': request.get('value')}).encode()
                header = struct.pack('>I', len(reply))
                if action == 'split':
                    os.write(1, header[:1])
                    os.write(1, header[1:])
                    for offset in range(0, len(reply), 3): os.write(1, reply[offset:offset+3])
                else:
                    os.write(1, header + reply)
            """#.utf8)
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
    private final class Spawn: @unchecked Sendable {
        private let lock = NSLock()
        private var value: pid_t?
        func record(_ pid: pid_t) { lock.lock(); value = pid; lock.unlock() }
        func read() -> pid_t? { lock.lock(); defer { lock.unlock() }; return value }
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
        let fixture = try Fixture(); defer { fixture.clean() }
        let reader = fixture.reader(), session = UUID()
        let first = try reply(await reader.exchange(request(value: 11), session: session))
        let second = try reply(await reader.exchange(request(value: 22), session: session))
        #expect(first.pid == second.pid && first.count == 1 && second.count == 2)
        #expect(first.value == 11 && second.value == 22)
        await reader.close()
        #expect(isReaped(first.pid))
    }

    @Test func anotherFeedUsesANewChildAndRetiresThePreviousOne() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let reader = fixture.reader()
        let first = try reply(await reader.exchange(request(), session: UUID()))
        let second = try reply(await reader.exchange(request(), session: UUID()))
        #expect(first.pid != second.pid && second.count == 1 && isReaped(first.pid))
        await reader.close()
    }

    @Test(arguments: ["oversize", "truncated"])
    func malformedFrameCannotBeConsumedByTheNextRequest(_ action: String) async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let reader = fixture.reader(), session = UUID(), spawned = Spawn()
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
        let fixture = try Fixture(); defer { fixture.clean() }
        let reader = fixture.reader(), session = UUID(), spawned = Spawn()
        let payload = request("hang")
        let job = Task { try await reader.exchange(payload, session: session, didSpawn: { spawned.record($0) }) }
        let deadline = ContinuousClock.now + .seconds(2)
        while spawned.read() == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let pid = try #require(spawned.read())
        let began = ContinuousClock.now
        job.cancel()
        await #expect(throws: CancellationError.self) { try await job.value }
        #expect(ContinuousClock.now - began < .seconds(1))
        #expect(isReaped(pid))
        let next = try reply(await reader.exchange(request(), session: session))
        #expect(next.pid != pid)
        await reader.close()
    }

    @Test func timeoutReapsChildAndDoesNotReturnAnyLateResponse() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let reader = fixture.reader(), spawned = Spawn(), session = UUID()
        await #expect(throws: (any Error).self) {
            try await reader.exchange(request("hang"), session: session, timeout: 0.2, didSpawn: { spawned.record($0) })
        }
        #expect(isReaped(try #require(spawned.read())))
        let next = try reply(await reader.exchange(request(), session: session))
        #expect(next.count == 1)
        await reader.close()
    }

    @Test func cancelledQueuedReadCannotRetireTheSuccessfulPredecessorsChild() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
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
        let fixture = try Fixture(); defer { fixture.clean() }
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
        let fixture = try Fixture(); defer { fixture.clean() }
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
        let fixture = try Fixture(); defer { fixture.clean() }
        let reader = fixture.reader()
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fixture.executable)
        await #expect(throws: (any Error).self) { try await reader.exchange(request(), session: UUID()) }
        await reader.close()
    }
}
