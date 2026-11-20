import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import NearpaneCore
import Security

/// Revocation can be observed on the serial pipe queue without blocking the main actor.
/// Once a step has been granted it may finish; each later step needs a fresh grant.
final class NativeSelectionPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    // Do not collect keys, events or window content. A new physical press supersedes an
    // older programmatic selection even when the user clicked outside Nearpane.
    static func inputCounters() -> [UInt32] {
        let kinds: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]
        return kinds.map { CGEventSource.counterForEventType(.hidSystemState, eventType: $0) }
    }

    private let current: @MainActor @Sendable () -> Bool
    private let checkOriginalWindow: @MainActor @Sendable () async -> Bool
    init(current: @escaping @MainActor @Sendable () -> Bool = { true },
         checkOriginalWindow: @escaping @MainActor @Sendable () async -> Bool = { true }) {
        self.current = current
        self.checkOriginalWindow = checkOriginalWindow
    }

    func gesturePermission(for id: UUID, after steps: Int) async -> NativeSpaceStepPermission {
        guard lock.withLock({ active }), await checkOriginalWindow() else {
            return .init(id: id, submittedSteps: steps, proceed: false)
        }
        return permission(for: id, after: steps)
    }

    func revoke() { lock.withLock { active = false } }
    func permission(for id: UUID, after steps: Int) -> NativeSpaceStepPermission {
        // The pipe actors do synchronous I/O. Keep the pipe serialized while the Host
        // checks this user intent, observation lifetime and sidebar visibility.
        let current = Thread.isMainThread ? MainActor.assumeIsolated { self.current() }
            : DispatchQueue.main.sync { self.current() }
        return lock.withLock { .init(id: id, submittedSteps: steps, proceed: active && current) }
    }
}

/// A single channel belongs to this Host. A timeout never replays a system gesture.
@MainActor final class NativeSpaceActionClient {
    static let shared = NativeSpaceActionClient()
    private let channel = SpaceActionChannel()

    func run(_ command: NativeSpaceCommand, permit: NativeSelectionPermit? = nil) async -> NativeSpaceReply {
        await channel.exchange(command, permit: permit)
    }
}

private actor SpaceActionChannel {
    private struct Connection {
        let process: Process
        let input, output: FileHandle

        func close() {
            try? input.close()
            try? output.close()
            if process.isRunning { process.terminate() }
        }
    }
    private let switchJournal = NativeSwitchJournal.installed()
    private var connection: Connection?
    private var exchanging = false
    private var waiting = [CheckedContinuation<Void, Never>]()

    private func connect() throws -> Connection {
        if let connection, connection.process.isRunning { return connection }
        connection?.close()
        connection = nil
        let root = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let executable = root.appendingPathComponent("Contents/Helpers/NearpaneSpaceAction")
        guard root.pathExtension == "app", executable.resolvingSymlinksInPath() == executable,
              let expected = Bundle.main.object(forInfoDictionaryKey: "NearpaneSpaceActionSHA256") as? String,
              try SHA256.hash(data: Data(contentsOf: executable, options: .mappedIfSafe))
                .map({ String(format: "%02x", $0) }).joined() == expected else { throw BundledAutomation.Missing.runtime }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else { throw BundledAutomation.Missing.runtime }
        let process = Process(), commands = Pipe(), replies = Pipe()
        guard fcntl(commands.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw CocoaError(.fileWriteUnknown) }
        process.executableURL = executable
        process.arguments = ["--serve"]
        process.standardInput = commands
        process.standardOutput = replies
        process.standardError = FileHandle.nullDevice
        try process.run()
        commands.fileHandleForReading.closeFile()
        replies.fileHandleForWriting.closeFile()
        let channel = Connection(process: process, input: commands.fileHandleForWriting, output: replies.fileHandleForReading)
        connection = channel
        return channel
    }

    private func readReply(_ channel: Connection, deadline: TimeInterval) throws -> NativeSpaceReply {
        var payload = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while payload.last != 10 {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            var fd = pollfd(fd: channel.output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard remaining > 0 else { throw CocoaError(.fileReadUnknown) }
            let ready = poll(&fd, 1, Int32(ceil(remaining * 1000)))
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { throw CocoaError(.fileReadUnknown) }
            let count = Darwin.read(fd.fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0, payload.count + count <= 16_384 else { throw CocoaError(.coderReadCorrupt) }
            payload.append(contentsOf: buffer.prefix(count))
        }
        return try JSONDecoder().decode(NativeSpaceReply.self, from: payload)
    }

    func exchange(_ command: NativeSpaceCommand, permit: NativeSelectionPermit?) async -> NativeSpaceReply {
        // Probes can arrive while the independent window worker checks its retained AX
        // element. Only one caller may consume replies from this helper at a time.
        if exchanging { await withCheckedContinuation { waiting.append($0) } }
        exchanging = true
        defer {
            if waiting.isEmpty { exchanging = false } else { waiting.removeFirst().resume() }
        }
        if command.action != .move && switchJournal.suspended {
            return .init(id: command.id, state: command.action == .probe ? .ready : .failed,
                         detail: "此系统版本的上次切换未获确认。请使用系统桌面控制。", canSwitch: false, canMove: false)
        }
        var journaled = false
        var mayHaveIssued = false
        do {
            try Task.checkCancellation()
            guard command.isFresh(at: ProcessInfo.processInfo.systemUptime) else { throw CocoaError(.userCancelled) }
            var request = try JSONEncoder().encode(command)
            guard request.count < 4096 else { throw CocoaError(.coderInvalidValue) }
            request.append(10)
            let channel = try connect()
            try Task.checkCancellation()
            if command.action == .select {
                try switchJournal.begin(command)
                journaled = true
            }
            try channel.input.write(contentsOf: request)
            mayHaveIssued = command.action == .move
            let deadline = command.deadlineUptime + 0.8
            var granted = 0
            while true {
                let reply = try readReply(channel, deadline: deadline)
                guard reply.id == command.id else { throw CocoaError(.coderReadCorrupt) }
                if reply.state != .awaitingStep {
                    if journaled { try switchJournal.finish(command, result: reply) }
                    return reply
                }
                guard command.action == .select, granted == 0, reply.submittedSteps == granted
                else { throw CocoaError(.coderReadCorrupt) }
                let decision = await permit?.gesturePermission(for: command.id, after: granted)
                    ?? .init(id: command.id, submittedSteps: granted, proceed: false)
                mayHaveIssued = mayHaveIssued || decision.proceed
                try channel.input.write(contentsOf: JSONEncoder().encode(decision) + Data([10]))
                granted += 1
            }
        } catch {
            connection?.close()
            connection = nil
            let result = NativeSpaceReply(id: command.id, state: mayHaveIssued ? .outcomeUnknown : .failed,
                                    detail: mayHaveIssued ? "空间助手未返回可核对的结果。" : "空间助手暂时不可用。",
                                    canSwitch: false, canMove: false)
            if journaled { try? switchJournal.finish(command, result: result) }
            return result
        }
    }
}
