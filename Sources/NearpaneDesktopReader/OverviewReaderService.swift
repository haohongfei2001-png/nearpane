import AppKit
import Darwin
import NearpaneCore

/// Reuses the signed reader process, never a snapshot, role or window identity.
/// Its AppKit run loop stays live between reads so screen/workspace changes can
/// invalidate framework caches. Only private pipe IO runs on the dedicated queue.
@MainActor final class OverviewReaderService {
    nonisolated private let io = DispatchQueue(label: "com.holdsnow.nearpane.overview-reader.io", qos: .userInitiated)
    private let parent = getppid()
    private var session: UUID?
    private var revision: UInt64 = 0

    func start() {
        guard fcntl(STDOUT_FILENO, F_SETNOSIGPIPE, 1) == 0 else { exit(2) }
        receive()
    }

    nonisolated private func receive() {
        io.async { [self] in
            do {
                guard let header = try Self.readExactly(4, allowEOF: true) else { exit(0) }
                let size = try DesktopReaderFrame.length(header, limit: DesktopReaderFrame.requestLimit)
                guard let bytes = try Self.readExactly(size, allowEOF: false) else { exit(2) }
                DispatchQueue.main.async { [self] in accept(bytes) }
            } catch { exit(2) }
        }
    }

    private func accept(_ bytes: Data) {
        do {
            let request = try JSONDecoder().decode(DesktopReadRequest.self, from: bytes)
            try DesktopReader.validate(request, overview: true)
            guard getppid() == parent, parent > 1, request.parentPID == parent,
                  session == nil || session == request.session, request.revision > revision,
                  request.fixtureWindows == nil, request.anchors.isEmpty, !request.experimentalSpaces else { exit(2) }
            session = request.session
            revision = request.revision
            // Each call constructs a new Reader and performs the original full
            // opening/closing CG, AX, topology, membership and session observations.
            let payload: Data = try autoreleasepool {
                let snapshot = try Reader(request: request).windowOverview()
                guard snapshot.isStructurallyValid, getppid() == parent else { throw DesktopActionError.unsupported }
                return try JSONEncoder().encode(snapshot)
            }
            let header = try DesktopReaderFrame.header(length: payload.count, limit: DesktopReaderFrame.responseLimit)
            io.async { [self] in
                do {
                    try Self.writeExactly(header)
                    try Self.writeExactly(payload)
                    receive()
                } catch { exit(3) }
            }
        } catch {
            FileHandle.standardError.write(Data("Read-only desktop sample unavailable.\n".utf8))
            exit(3)
        }
    }

    nonisolated private static func readExactly(_ count: Int, allowEOF: Bool) throws -> Data? {
        var bytes = Data(count: count), offset = 0
        while offset < count {
            let received = bytes.withUnsafeMutableBytes { raw in
                Darwin.read(STDIN_FILENO, raw.baseAddress!.advanced(by: offset), count - offset)
            }
            if received > 0 { offset += received }
            else if received == 0 {
                if allowEOF && offset == 0 { return nil }
                throw DesktopReaderFrame.Failure.invalidLength
            } else if errno != EINTR { throw DesktopReaderFrame.Failure.invalidLength }
        }
        return bytes
    }

    nonisolated private static func writeExactly(_ bytes: Data) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw in
                Darwin.write(STDOUT_FILENO, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if written > 0 { offset += written }
            else if written < 0 && errno == EINTR { continue }
            else { throw DesktopReaderFrame.Failure.invalidLength }
        }
    }
}
