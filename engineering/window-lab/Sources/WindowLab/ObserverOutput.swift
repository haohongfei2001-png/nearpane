import Darwin
import Foundation

/// The Host polls for new revisions while the reader is still producing its sample.
package func publishObserverOutput(at output: URL, run: (FileHandle) throws -> Void) throws {
    let stage = output.deletingLastPathComponent().appendingPathComponent(".observer-" + UUID().uuidString)
    let fd = open(stage.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { unlink(stage.path) }
    try run(handle)
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_size > 0 else { throw Refusal("observer returned no data") }
    try handle.close()
    guard renamex_np(stage.path, output.path, UInt32(RENAME_EXCL)) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
