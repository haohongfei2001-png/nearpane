import Foundation
import NearpaneCore

enum StepHandshake {
    static func exchange(_ receipt: NativeSpaceReply, input: FileHandle, output: FileHandle,
                         timeout: TimeInterval = 0.5) throws -> NativeSpaceStepPermission {
        do {
            return try SelectionStepHandshake.exchange(receipt, input: input, output: output, timeout: timeout)
        } catch {
            throw ActionFailure("空间选择确认已中断或超时。")
        }
    }
}
