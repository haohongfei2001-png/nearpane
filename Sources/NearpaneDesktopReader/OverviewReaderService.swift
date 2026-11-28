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
            var phase = "request-header-read"
            do {
                guard let header = try Self.readExactly(4, allowEOF: true) else { exit(0) }
                phase = "request-header-length"
                let size = try DesktopReaderFrame.length(header, limit: DesktopReaderFrame.requestLimit)
                phase = "request-body-read"
                guard let bytes = try Self.readExactly(size, allowEOF: false) else { exit(2) }
                DispatchQueue.main.async { [self] in accept(bytes) }
            } catch {
                Self.traceFailure(phase, error: error)
                exit(2)
            }
        }
    }

    private func accept(_ bytes: Data) {
        let tracing = ProcessInfo.processInfo.environment["NP_SPACES_LAUNCH_TRACE"] != nil
        var phase = "request-decode"
        var receivedRequest: DesktopReadRequest?, receivedSnapshot: DesktopSnapshot?
        var snapshotValidated: Bool?
        do {
            let request = try JSONDecoder().decode(DesktopReadRequest.self, from: bytes)
            receivedRequest = request
            phase = "request-validation"
            try DesktopReader.validate(request, overview: true)
            phase = "request-parent-session-revision"
            guard getppid() == parent, parent > 1, request.parentPID == parent,
                  session == nil || session == request.session, request.revision > revision,
                  request.fixtureWindows == nil, request.anchors.isEmpty, !request.experimentalSpaces else {
                Self.traceFailure(phase, request: request)
                exit(2)
            }
            session = request.session
            revision = request.revision
            // Each call constructs a new Reader and performs the original full
            // opening/closing CG, AX, topology, membership and session observations.
            let payload: Data = try autoreleasepool {
                phase = "native-sample"
                let diagnostic: ((String) -> Void)? = tracing ? { phase = "native/" + $0 } : nil
                let snapshot = try Reader(request: request).windowOverview(diagnostic: diagnostic)
                if tracing { receivedSnapshot = snapshot }
                phase = "snapshot-validation-and-parent"
                let valid = snapshot.isStructurallyValid
                if tracing { snapshotValidated = valid }
                guard valid, getppid() == parent else { throw DesktopActionError.unsupported }
                phase = "response-encode"
                return try JSONEncoder().encode(snapshot)
            }
            phase = "response-header-length"
            let header = try DesktopReaderFrame.header(length: payload.count, limit: DesktopReaderFrame.responseLimit)
            io.async { [self] in
                var phase = "response-header-write"
                do {
                    try Self.writeExactly(header)
                    phase = "response-body-write"
                    try Self.writeExactly(payload)
                    receive()
                } catch {
                    Self.traceFailure(phase, error: error, request: request)
                    exit(3)
                }
            }
        } catch {
            Self.traceFailure(phase, error: error, request: receivedRequest, snapshot: receivedSnapshot,
                              snapshotValidated: snapshotValidated)
            FileHandle.standardError.write(Data("Read-only desktop sample unavailable.\n".utf8))
            exit(3)
        }
    }

    /// Opt-in failure facts only. No window title, content, raw request/response,
    /// error description or extra native observation is included.
    nonisolated private static func traceFailure(_ phase: String, error: Error? = nil,
                                                 request: DesktopReadRequest? = nil, snapshot: DesktopSnapshot? = nil,
                                                 snapshotValidated: Bool? = nil) {
        guard ProcessInfo.processInfo.environment["NP_SPACES_LAUNCH_TRACE"] != nil else { return }
        var facts: [String: Any] = ["event": "desktopOverviewServiceFailure", "phase": phase,
            "uptime": ProcessInfo.processInfo.systemUptime]
        if let error { facts["errorType"] = String(String(reflecting: type(of: error)).prefix(120)) }
        if let snapshotValidated { facts["snapshotStructurallyValid"] = snapshotValidated }
        if let request {
            facts["readSession"] = request.session.uuidString
            facts["requestRevision"] = request.revision
        }
        if let snapshot {
            facts["windowCount"] = snapshot.windows.count
            facts["displayCount"] = snapshot.displays.count
            facts["scopeCount"] = snapshot.scopes.count
            facts["catalogComplete"] = snapshot.native?.catalogComplete.map { $0 as Any } ?? NSNull()
            facts["catalogIssueCount"] = snapshot.native?.catalogIssues?.count ?? 0
            if let census = snapshot.native?.catalogCensus,
               let data = try? JSONEncoder().encode(census),
               let counts = try? JSONSerialization.jsonObject(with: data) {
                facts["catalogCensus"] = counts
            }
        }
        if var data = try? JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys]) {
            data.append(0x0a)
            try? FileHandle.standardError.write(contentsOf: data)
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
