import CryptoKit
import Darwin
import Foundation
import NearpaneCore
import Security

/// A single channel belongs to this Host. A timeout never replays a system gesture.
@MainActor final class NativeSpaceActionClient {
    static let shared = NativeSpaceActionClient()
    private let channel = SpaceActionChannel()

    func run(_ command: NativeSpaceCommand) async -> NativeSpaceReply {
        await channel.exchange(command)
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
    private var connection: Connection?

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

    func exchange(_ command: NativeSpaceCommand) -> NativeSpaceReply {
        var submitted = false
        do {
            try Task.checkCancellation()
            var request = try JSONEncoder().encode(command)
            guard request.count < 4096 else { throw CocoaError(.coderInvalidValue) }
            request.append(10)
            let channel = try connect()
            try Task.checkCancellation()
            try channel.input.write(contentsOf: request)
            submitted = true
            let deadline = ProcessInfo.processInfo.systemUptime + 6
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
            let reply = try JSONDecoder().decode(NativeSpaceReply.self, from: payload)
            guard reply.id == command.id else { throw CocoaError(.coderReadCorrupt) }
            return reply
        } catch {
            connection?.close()
            connection = nil
            return NativeSpaceReply(id: command.id, state: submitted ? .outcomeUnknown : .failed,
                                    detail: submitted ? "空间助手未返回可核对的结果。" : "空间助手暂时不可用。",
                                    canSwitch: false, canMove: false)
        }
    }
}
