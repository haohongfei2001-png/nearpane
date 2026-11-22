import Darwin
import Foundation

/// Read through the directory descriptor held since R. A previous job, receipt alias or partial
/// publication cannot establish that this particular live Guardian surrendered its reference.
struct CornerWithdrawalReceipt: Decodable {
    struct Proof: Decodable {
        let intent, transaction, group, member, generation, lifetime, display, space: UUID
        let epoch, native, birth, hostBirth, guardianBirth: UInt64
        let pid, hostPID: Int32
        let window: UInt32
        let frame: [Double]
        let originalReadbacks: Int
    }
    let schema, issued: Int
    let guardianPID: Int32
    let status: String
    let retainedBeforePark, committedPostimage, originalPipeEOF, kernelHostExit: Bool
    let withdrawal: Proof

    func matches(_ r: NativeStageEngineRequest, epoch: UInt64, host: Int32, hostBirth: UInt64,
                 child: Int32, childBirth: UInt64) -> Bool {
        let p = withdrawal
        guard let frame = r.frame, let window = r.window, hostBirth > 0, childBirth > 0 else { return false }
        return schema == 1 && status == "WITHDRAWN_BEFORE_SUBMISSION" && issued == 0 &&
            retainedBeforePark && !committedPostimage && !originalPipeEOF && !kernelHostExit &&
            guardianPID == child && p.guardianBirth == childBirth && p.hostPID == host && p.hostBirth == hostBirth &&
            r.backend == 1 && r.operation == 3 && p.epoch == epoch && p.originalReadbacks == 2 &&
            p.intent == r.intent && p.group == r.group && p.member == r.member && p.generation == r.generation &&
            p.lifetime == r.lifetime && p.display == r.scope?.display && p.space == r.scope?.nativeSpace &&
            p.native == r.nativeID && p.pid == window.pid && p.window == window.number && p.birth == window.birth &&
            p.frame == [frame.x, frame.y, frame.width, frame.height]
    }

    static func read(in directory: Int32) -> Self? {
        var job = stat()
        guard fstat(directory, &job) == 0, job.st_uid == getuid(), job.st_mode & S_IFMT == S_IFDIR,
              job.st_mode & 0o777 == 0o700 else { return nil }
        let name = "guardian-receipt.json"
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var file = stat()
        guard fstat(fd, &file) == 0, file.st_mode & S_IFMT == S_IFREG, file.st_uid == getuid(),
              file.st_mode & 0o777 == 0o600, file.st_nlink == 1, (2...16_384).contains(file.st_size) else { return nil }
        var bytes = Data(count: Int(file.st_size))
        let length = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
        var current = stat()
        guard length == file.st_size, fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_ino == file.st_ino, current.st_dev == file.st_dev, current.st_nlink == 1,
              current.st_mode == file.st_mode, current.st_size == file.st_size,
              current.st_mtimespec.tv_sec == file.st_mtimespec.tv_sec,
              current.st_mtimespec.tv_nsec == file.st_mtimespec.tv_nsec else { return nil }
        return try? JSONDecoder().decode(Self.self, from: bytes)
    }
}
