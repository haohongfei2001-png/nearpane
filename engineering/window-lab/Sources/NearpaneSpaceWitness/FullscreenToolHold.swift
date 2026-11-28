import AppKit
import CryptoKit
import WindowLab

extension Trial {
    private func checkpointBytes(_ name: String, limit: Int) -> Data? {
        let fd = open(dir.appendingPathComponent(name).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == getuid(), info.st_size > 0, info.st_size <= limit,
              let bytes = try? file.read(upToCount: limit + 1), bytes.count == info.st_size else { return nil }
        return bytes
    }

    /// Wait for the independent Host-side controller. This witness attests system state and
    /// correlates the reply. Only that controller can independently judge the real tool interaction.
    func holdForTools(origin: Position, display: String, fullscreen: String,
                      validate: () throws -> Void) throws {
        let expiry = try toolObservationCutoff()
        guard expiry > ProcessInfo.processInfo.systemUptime else {
            toolObservationResult = "insufficient-time"
            return
        }
        guard let executable = Bundle.main.executableURL, let boot = consoleBoot else {
            throw Refusal("missing fullscreen witness identity")
        }
        func sha(_ url: URL) throws -> String {
            try SHA256.hash(data: Data(contentsOf: url, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
        }
        let reader = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NearpaneDesktopReader")
        let challenge = try FullscreenToolChallenge(run: run, display: display, source: origin.record,
            fullscreenCurrent: fullscreen, boot: boot, build: origin.build, pid: birth.pid,
            launch: birth.start, number: origin.number, revision: revision, expiresUptime: expiry,
            witnessSHA256: sha(executable), readerSHA256: sha(reader))
        try writeJSON(challenge, dir, "fullscreen-tools-challenge.json")
        var status = "interrupted", reply: FullscreenToolReply?
        defer {
            toolObservationResult = status
            var summary = ["run": run.uuidString, "token": challenge.token.uuidString, "status": status]
            if let reply {
                summary["hostPID"] = String(reply.hostPID)
                summary["receiptSHA256"] = reply.receiptSHA256
            }
            try? writeJSON(summary, dir, "fullscreen-tools-end.json")
        }
        let response = dir.appendingPathComponent("fullscreen-tools-response.json")
        var nextRead = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime < expiry {
            try checkConsentExpiry()
            if ProcessInfo.processInfo.systemUptime >= nextRead {
                try validate()
                nextRead = ProcessInfo.processInfo.systemUptime + 1
            }
            if FileManager.default.fileExists(atPath: response.path) {
                guard let bytes = checkpointBytes("fullscreen-tools-response.json", limit: 4096),
                      let decoded = try? JSONDecoder().decode(FullscreenToolReply.self, from: bytes),
                      let receipt = checkpointBytes("fullscreen-tools-receipt.json", limit: 1_048_576),
                      SHA256.hash(data: receipt).map({ String(format: "%02x", $0) }).joined() == decoded.receiptSHA256,
                      decoded.matches(challenge, uptime: ProcessInfo.processInfo.systemUptime) else {
                    status = "invalid-response"
                    return
                }
                try validate()
                reply = decoded
                status = "controller-" + decoded.result.rawValue
                return
            }
            pump()
        }
        status = "timeout"
    }
}
