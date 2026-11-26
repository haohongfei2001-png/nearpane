import Foundation

/// Release evidence is separate from ordinary runtime health. No profile is
/// shipped as a pretend measurement: its absence preserves real line syncing.
struct ClockQualificationFile: Codable, Sendable {
    let schemaVersion: Int
    let records: [ClockQualificationRecord]
}
struct ClockQualificationRecord: Codable, Sendable {
    let player: PlayerID
    let playerVersion: String
    let playerBuild: String
    let systemBuild: String
    let adapterRevision: String
    let dataOrigin: String
    let referenceKind: String
    let evidenceSHA256: String
    let measuredAt: Date
    let expiresAt: Date
    let sampleCount: Int
    let recordingCount: Int
    let referenceUncertaintyMS: Double
    /// Includes the upper bound of independent-reference uncertainty.
    let positionErrorP95MS: Double

    func matches(process: PlayerProcess, build: String, now: Date) -> Bool {
        player == process.player && playerVersion == process.version && !playerVersion.isEmpty && playerVersion != "unknown"
        && playerBuild == process.build && !playerBuild.isEmpty && playerBuild != "unknown"
        && systemBuild == build && build != "unknown" && build != "unsupported"
        && adapterRevision == (player.usesAppleEvents ? AppleEventClient.revision : MediaRemoteClient.revision)
        && dataOrigin == "real_player" && referenceKind == "independent_position_reference"
        && evidenceSHA256.utf8.count == 64 && evidenceSHA256.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
        && measuredAt <= now && expiresAt > now && expiresAt > measuredAt
        && expiresAt.timeIntervalSince(measuredAt) <= 90 * 86_400
        && sampleCount >= 100 && recordingCount >= 10
        && positionErrorP95MS.isFinite && positionErrorP95MS > 0 && positionErrorP95MS <= 250
        && referenceUncertaintyMS.isFinite && referenceUncertaintyMS >= 0 && referenceUncertaintyMS <= positionErrorP95MS
    }
}
struct ClockQualifications: Sendable {
    var records: [ClockQualificationRecord] = []
    static func load() -> ClockQualifications {
        var urls: [URL] = []
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            urls.append(support.appendingPathComponent("HOLDSNOW/LyricTile/PlaybackClockQualification.json"))
        }
        if let bundle = Bundle.main.resourceURL { urls.append(bundle.appendingPathComponent("PlaybackClockQualification.json")) }
        var records: [ClockQualificationRecord] = []
        for url in urls {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 64 * 1024 + 1), data.count <= 64 * 1024 else { continue }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            guard let decoded = try? decoder.decode(ClockQualificationFile.self, from: data), decoded.schemaVersion == 1,
                  decoded.records.count <= 32 else { continue }
            records.append(contentsOf: decoded.records)
        }
        return ClockQualifications(records: records)
    }
    func applying(to input: PlayerObservation, systemBuild: String, now: Date = Date()) -> PlayerObservation {
        var output = input
        guard input.positionMS != nil, input.quality == .coarseSourceAnchor,
              input.state == .playing || input.state == .paused,
              let record = records.filter({ $0.matches(process: input.process, build: systemBuild, now: now) })
                .max(by: { $0.measuredAt < $1.measuredAt }) else { return output }
        output.quality = .verifiedSourceAnchor
        output.expectedErrorMS = Int64(record.positionErrorP95MS.rounded(.up))
        return output
    }
}
