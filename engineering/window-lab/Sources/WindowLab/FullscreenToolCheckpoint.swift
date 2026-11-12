import Foundation

package struct FullscreenToolChallenge: Codable {
    package let run, token: UUID
    package let display, source, fullscreenCurrent, boot, build: String
    package let pid: Int32, launch: UInt64, number: UInt32, revision: UInt64
    package let expiresUptime: Double
    package let witnessSHA256, readerSHA256: String

    package init(run: UUID, display: String, source: String, fullscreenCurrent: String, boot: String, build: String,
                 pid: Int32, launch: UInt64, number: UInt32, revision: UInt64, expiresUptime: Double,
                 witnessSHA256: String, readerSHA256: String) {
        self.run = run; self.token = UUID(); self.display = display; self.source = source
        self.fullscreenCurrent = fullscreenCurrent; self.boot = boot; self.build = build
        self.pid = pid; self.launch = launch; self.number = number; self.revision = revision
        self.expiresUptime = expiresUptime; self.witnessSHA256 = witnessSHA256; self.readerSHA256 = readerSHA256
    }
}

package struct FullscreenToolReply: Decodable {
    package enum Result: String, Decodable { case observed, inconclusive }
    let run, token: UUID
    let display: String, pid: Int32, launch: UInt64, number: UInt32
    package let hostPID: Int32, receiptSHA256: String, result: Result

    package func matches(_ request: FullscreenToolChallenge, uptime: Double) -> Bool {
        run == request.run && token == request.token && display == request.display &&
        pid == request.pid && launch == request.launch && number == request.number &&
        hostPID > 1 && hostPID != pid && uptime.isFinite && uptime >= 0 && uptime < request.expiresUptime &&
        receiptSHA256.utf8.count == 64 && receiptSHA256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
