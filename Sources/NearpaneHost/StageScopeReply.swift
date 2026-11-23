import Darwin
import Foundation

/// Fixed, per-invocation files for a nonactivating Launch Services readback. No user-supplied file path.
final class StageScopeReply {
    private let directory: Int32

    init(_ challenge: UUID) throws {
        let path = "/private/tmp/nearpane-host-scope." + challenge.uuidString.lowercased()
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var status = stat()
        guard fd >= 0 else { throw CocoaError(.fileNoSuchFile) }
        guard fstat(fd, &status) == 0, status.st_uid == getuid(), status.st_mode & 0o777 == 0o700 else {
            close(fd)
            throw CocoaError(.fileReadNoPermission)
        }
        directory = fd
    }

    deinit { close(directory) }

    /// Only the fixed, per-nonce rendezvous names may be awaited. No caller-supplied pathname.
    enum Signal: String {
        case launch = "launched", registration = "fixture.json", abort = "abort"
        case guardianSurvival = "guardian-survival.request", cornerReadback = "corner-readback.request"
    }

    func exists(_ signal: Signal) throws -> Bool {
        var info = stat()
        if fstatat(directory, signal.rawValue, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw CocoaError(.fileReadUnknown) }
            return false
        }
        guard info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600 else { throw CocoaError(.fileReadNoPermission) }
        return true
    }

    @MainActor func wait(for signal: Signal, seconds: Int) async throws {
        let clock = ContinuousClock(), end = clock.now + .seconds(seconds)
        while clock.now < end {
            if try exists(.abort) { throw CancellationError() }
            if try exists(signal) { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        throw CocoaError(.fileReadUnknown)
    }

    func registration() throws -> Data {
        let fd = openat(directory, "fixture.json", O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw CocoaError(.fileNoSuchFile) }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o777 == 0o600,
              info.st_uid == getuid(), info.st_nlink == 1, (1...4096).contains(info.st_size),
              let data = try input.read(upToCount: 4097), data.count == info.st_size else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }

    func finish(_ data: Data, preflight: Bool = false) throws {
        let fd = openat(directory, preflight ? "preflight.json" : "response.json", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteFileExists) }
        let out = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try out.write(contentsOf: data)
        try out.synchronize()
        try out.close()
    }
}
