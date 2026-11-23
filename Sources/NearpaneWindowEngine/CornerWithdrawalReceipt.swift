import Darwin
import Foundation
import CNearpaneWindowEngine

/// Shared binding for the live Guardian's prepared and withdrawn records. A disk record never grants a writer.
struct CornerGuardianOriginalProof: Decodable, Equatable {
    let intent, transaction, group, member, generation, lifetime, display, space: UUID
    let epoch, native, birth, hostBirth, guardianBirth: UInt64
    let pid, hostPID: Int32
    let window: UInt32
    let frame: [Double]
    let originalReadbacks: Int

    func matches(_ request: NativeStageEngineRequest, epoch: UInt64, host: Int32, hostBirth: UInt64, childBirth: UInt64) -> Bool {
        guard let original = request.frame, let target = request.window, hostBirth > 0, childBirth > 0 else { return false }
        return request.backend == 1 && request.operation == 3 && self.epoch == epoch && originalReadbacks == 2 &&
            guardianBirth == childBirth && hostPID == host && self.hostBirth == hostBirth &&
            intent == request.intent && group == request.group && member == request.member && generation == request.generation &&
            lifetime == request.lifetime && display == request.scope?.display && space == request.scope?.nativeSpace &&
            native == request.nativeID && pid == target.pid && window == target.number && birth == target.birth &&
            frame == [original.x, original.y, original.width, original.height]
    }
}

struct CornerPreparedReceipt: Decodable, Equatable {
    let schema: Int, status: String, guardianPID: Int32, original: CornerGuardianOriginalProof

    func matches(_ request: NativeStageEngineRequest, epoch: UInt64, host: Int32, hostBirth: UInt64,
                 child: Int32, childBirth: UInt64) -> Bool {
        schema == 1 && status == "PREPARED" && guardianPID == child &&
            original.matches(request, epoch: epoch, host: host, hostBirth: hostBirth, childBirth: childBirth)
    }

    static func read(in directory: Int32) -> Self? { CornerGuardianRecord.prepared.read(Self.self, in: directory) }
}

struct CornerWithdrawalReceipt: Decodable {
    let schema, issued: Int
    let guardianPID: Int32
    let status: String
    let retainedBeforePark, committedPostimage, originalPipeEOF, kernelHostExit: Bool
    let withdrawal: CornerGuardianOriginalProof

    func matches(_ r: NativeStageEngineRequest, epoch: UInt64, host: Int32, hostBirth: UInt64,
                 child: Int32, childBirth: UInt64) -> Bool {
        schema == 1 && status == "WITHDRAWN_BEFORE_SUBMISSION" && issued == 0 &&
            retainedBeforePark && !committedPostimage && !originalPipeEOF && !kernelHostExit && guardianPID == child &&
            withdrawal.matches(r, epoch: epoch, host: host, hostBirth: hostBirth, childBirth: childBirth)
    }

    static func read(in directory: Int32) -> Self? { CornerGuardianRecord.final.read(Self.self, in: directory) }
}

struct CornerMeasuredFrameReceipt: Decodable {
    let schema: Int, status: String, guardianPID: Int32
    let original: CornerGuardianOriginalProof, postimage: [Double]
    let engineStatus, engineFlags: UInt32

    static func isMeasurement(_ raw: NativeStageEngineReceipt) -> Bool {
        let flags = UInt32(NP_AX_VALID | NP_CG_VALID | NP_MEMBERSHIP_VALID | NP_OWNED | NP_CORNER_RECOVERY_FRAME)
        return raw.status == NP_UNKNOWN && (1...32).contains(raw.owned) && raw.flags == flags
    }

    func matches(_ raw: NativeStageEngineReceipt, prepared: CornerPreparedReceipt) -> Bool {
        let frame = raw.frame
        return Self.isMeasurement(raw) && schema == 1 && status == "RECOVERY_FRAME_ONLY" && guardianPID == prepared.guardianPID &&
            original == prepared.original && raw.intent == original.intent && raw.epoch == original.epoch &&
            raw.nativeID == original.native && raw.status == engineStatus && raw.flags == engineFlags &&
            postimage == [frame.x, frame.y, frame.width, frame.height] && postimage.allSatisfy(\.isFinite) &&
            frame.width > 0 && frame.height > 0
    }

    static func read(in directory: Int32) -> Self? { CornerGuardianRecord.observed.read(Self.self, in: directory) }
}

/// Read through the exact directory descriptor opened before launching this Guardian.
private enum CornerGuardianRecord: String {
    case prepared = "guardian-prepared.json", observed = "guardian-observed.json", final = "guardian-receipt.json"

    func read<T: Decodable>(_ type: T.Type, in directory: Int32) -> T? {
        var job = stat()
        guard fstat(directory, &job) == 0, job.st_uid == getuid(), job.st_mode & S_IFMT == S_IFDIR,
              job.st_mode & 0o777 == 0o700 else { return nil }
        let fd = openat(directory, rawValue, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var file = stat()
        guard fstat(fd, &file) == 0, file.st_mode & S_IFMT == S_IFREG, file.st_uid == getuid(),
              file.st_mode & 0o777 == 0o600, file.st_nlink == 1, (2...16_384).contains(file.st_size) else { return nil }
        var bytes = Data(count: Int(file.st_size))
        let length = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
        var current = stat()
        guard length == file.st_size, fstatat(directory, rawValue, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_ino == file.st_ino, current.st_dev == file.st_dev, current.st_nlink == 1,
              current.st_mode == file.st_mode, current.st_size == file.st_size,
              current.st_mtimespec.tv_sec == file.st_mtimespec.tv_sec,
              current.st_mtimespec.tv_nsec == file.st_mtimespec.tv_nsec else { return nil }
        return try? JSONDecoder().decode(type, from: bytes)
    }
}
