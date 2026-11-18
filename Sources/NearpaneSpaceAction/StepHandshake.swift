import Darwin
import Foundation
import NearpaneCore

enum StepHandshake {
    /// The peer never has to close its pipe between messages. Limit time and
    /// bytes for the entire envelope, even if it sends only an initial byte.
    static func exchange(_ receipt: NativeSpaceReply, input: FileHandle, output: FileHandle,
                         timeout: TimeInterval = 0.5) throws -> NativeSpaceStepPermission {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        try output.write(contentsOf: JSONEncoder().encode(receipt) + Data([10]))
        var line = Data()
        while line.count < 512 {
            let left = deadline - ProcessInfo.processInfo.systemUptime
            guard left > 0 else { throw ActionFailure("空间选择确认已超时。") }
            var fd = pollfd(fd: input.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&fd, 1, Int32(ceil(left * 1000)))
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0, fd.revents & Int16(POLLIN) != 0 else { throw ActionFailure("空间选择确认已中断。") }
            var byte: UInt8 = 0
            let n = Darwin.read(fd.fd, &byte, 1)
            if n < 0 && errno == EINTR { continue }
            guard n == 1 else { throw ActionFailure("空间选择确认不完整。") }
            if byte == 10 { return try JSONDecoder().decode(NativeSpaceStepPermission.self, from: line) }
            line.append(byte)
        }
        throw ActionFailure("空间选择确认超长。")
    }
}
