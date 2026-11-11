import AppKit
import CryptoKit
import Darwin
import NearpaneCore

struct OrdinaryWindowFailure: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
    init(_ reason: String) { self.reason = reason }
}

private actor OrdinaryWindowChannel {
    private let process: Process
    private let input, output: FileHandle

    init() throws {
        let root = Bundle.main.bundleURL
        let executable = root.appendingPathComponent("Contents/Helpers/NearpaneOrdinaryWindowController")
        guard executable.resolvingSymlinksInPath().path == executable.path,
              let expected = Bundle.main.object(forInfoDictionaryKey: "NearpaneOrdinaryWindowControllerSHA256") as? String,
              try SHA256.hash(data: Data(contentsOf: executable, options: .mappedIfSafe))
                .map({ String(format: "%02x", $0) }).joined() == expected
        else { throw OrdinaryWindowFailure("无法核验此版本的窗口控制助手。") }
        let process = Process(), commands = Pipe(), replies = Pipe()
        // If the helper dies between isRunning and write(2), return EPIPE without
        // delivering SIGPIPE to the Host (which also owns the text and screenshot stores).
        guard fcntl(commands.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0
        else { throw OrdinaryWindowFailure("无法安全建立窗口控制通道。") }
        process.executableURL = executable
        process.standardInput = commands
        process.standardOutput = replies
        process.standardError = FileHandle.nullDevice
        try process.run()
        commands.fileHandleForReading.closeFile()
        replies.fileHandleForWriting.closeFile()
        self.process = process
        input = commands.fileHandleForWriting
        output = replies.fileHandleForReading
    }

    nonisolated func interrupt() {
        if process.isRunning { process.terminate() }
    }

    deinit {
        try? input.close()
        try? output.close()
    }

    func call(_ command: OrdinaryWindowRequest) throws -> OrdinaryWindowReply {
        guard process.isRunning else { throw OrdinaryWindowFailure("窗口助手已结束，原授权失效。") }
        let reply: OrdinaryWindowReply
        do {
            var bytes = try JSONEncoder().encode(command)
            bytes.append(10)
            try input.write(contentsOf: bytes)
            var result = Data()
            let deadline = ProcessInfo.processInfo.systemUptime + 8
            while result.count <= 64_000 {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
                guard remaining > 0,
                      poll(&descriptor, 1, Int32(min(remaining * 1000, 8000))) > 0
                else { throw OrdinaryWindowFailure("窗口助手超时或已停止，保留恢复记录。") }
                // On Darwin FileHandle.read(upToCount:) waits for the count or EOF. This pipe
                // carries many newline-delimited replies and intentionally stays open.
                var buffer = [UInt8](repeating: 0, count: 8192)
                let n = Darwin.read(output.fileDescriptor, &buffer, buffer.count)
                guard n > 0 else { throw OrdinaryWindowFailure("窗口助手已结束，保留恢复记录。") }
                result.append(contentsOf: buffer.prefix(n))
                if result.last == 10 { break }
            }
            reply = try JSONDecoder().decode(OrdinaryWindowReply.self, from: result)
            guard reply.nonce == command.nonce else { throw OrdinaryWindowFailure("收到过期的窗口操作回执。") }
        } catch {
            try? input.close()
            if process.isRunning { process.terminate() }
            throw error
        }
        if let error = reply.failure { throw OrdinaryWindowFailure(error) }
        return reply
    }
}

@MainActor final class OrdinaryWindowDirectory {
    let app: AdmissionApplication
    private let channel: OrdinaryWindowChannel
    private(set) var handles = [UUID: OrdinaryWindowAX]()

    init(_ app: AdmissionApplication) throws {
        self.app = app
        channel = try OrdinaryWindowChannel()
    }

    func choices(initial: Bool) async throws -> [AdmissionWindowChoice] {
        let action: OrdinaryWindowRequest.Action = initial ? .list : .refresh
        let result = try await channel.call(.init(action, pid: app.pid, launch: app.launch, bundle: app.bundle))
        guard let choices = result.choices, choices.count <= 64 else { throw OrdinaryWindowFailure("窗口清单不完整。") }
        var next = [UUID: OrdinaryWindowAX]()
        let rows = try choices.enumerated().map { index, id -> AdmissionWindowChoice in
            guard let id else { return .init(id: UUID(), number: nil, index: index + 1) }
            guard id.pid == app.pid, id.launch == app.launch, id.number != 0, next[id.element] == nil
            else { throw OrdinaryWindowFailure("无法核对窗口清单身份。") }
            next[id.element] = handles[id.element] ?? OrdinaryWindowAX(id: id, bundle: app.bundle, channel: channel)
            return .init(id: id.element, number: id.number, index: index + 1)
        }
        handles = next
        return rows
    }
}

@MainActor final class OrdinaryWindowAX {
    let id: ManagedWindowID, bundle: String
    private let channel: OrdinaryWindowChannel
    private var closed = false
    private(set) var lastWriteSteps = [OrdinaryWindowStep]()

    fileprivate init(id: ManagedWindowID, bundle: String, channel: OrdinaryWindowChannel) {
        self.id = id
        self.bundle = bundle
        self.channel = channel
    }

    deinit {
        let command = OrdinaryWindowRequest(.release, pid: id.pid, launch: id.launch, bundle: bundle, id: id)
        Task { [channel] in _ = try? await channel.call(command) }
    }

    func prepare() async throws -> AdmissionPair { try await sample(.prepare) }
    func verify(expected: SurfaceRect) async throws -> AdmissionPair { try await sample(.verify, from: expected) }
    func write(from: SurfaceRect, to: SurfaceRect) async throws -> AdmissionPair {
        try await sample(.write, from: from, to: to)
    }

    private func sample(_ action: OrdinaryWindowRequest.Action, from: SurfaceRect? = nil, to: SurfaceRect? = nil) async throws -> AdmissionPair {
        guard !closed else { throw OrdinaryWindowFailure("该窗口授权已结束。") }
        let response = try await channel.call(.init(action, pid: id.pid, launch: id.launch, bundle: bundle,
                                                    id: id, expected: from, destination: to))
        if !closed, action == .verify, let witness = response.closure, witness.id == id, response.pair == nil {
            throw witness
        }
        guard let pair = response.pair, pair.first.id == id, pair.second.id == id,
              !closed else { throw OrdinaryWindowFailure("所选窗口身份已失效。") }
        if action == .write { lastWriteSteps = response.steps ?? [] }
        return pair
    }

    func invalidate() {
        closed = true
        channel.interrupt()
    }

}
