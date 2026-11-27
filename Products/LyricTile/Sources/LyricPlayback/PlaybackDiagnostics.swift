import Foundation

struct DiagnosticPlayer: Codable, Sendable {
    let player: String
    let bundleID: String
    let pid: Int32
    let processStartMicros: UInt64
    let mediaPID: Int32
    let mediaProcessStartMicros: UInt64
    let version: String
    let build: String
    let title: String?
    let artist: String?
    let album: String?
    let platformID: String?
    let durationMS: Int64?
    let positionMS: Int64?
    let state: String
    let observedUptimeNanoseconds: UInt64
    let quality: String
    let expectedErrorMS: Int64?
    let isCurrentSystemSource: Bool
    let capabilities: TransportCapabilities
}
struct TransportTrace: Codable, Sendable {
    let id: UUID
    let intent: String
    let seekMS: Int64?
    let targetBundleID: String
    let sessionID: UUID
    let generation: UInt64
    let startedUptimeNanoseconds: UInt64
    let finishedUptimeNanoseconds: UInt64
    let observedSystemOwnerBefore: String?
    let observedSystemPIDBefore: Int32?
    let observedSystemOwnerAfter: String?
    let observedSystemPIDAfter: Int32?
    let outcome: String
}
struct PlaybackDiagnosticReport: Codable, Sendable {
    let dataOrigin: String
    let exportedAt: Date
    let systemBuild: String
    let appleEventsRevision: String
    let mediaRemoteRevision: String
    let selectedPlayer: String?
    let players: [DiagnosticPlayer]
    let currentMediaRemotePayload: [String: JSONValue]?
    let commands: [TransportTrace]
}
