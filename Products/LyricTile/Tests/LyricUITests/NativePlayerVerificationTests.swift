import Foundation
import LyricPlayback
import Testing
@testable import LyricUI

@Suite("Native paused-clock verification")
@MainActor
struct NativePlayerVerificationTests {
    private func reports() throws -> (before: [String: Any], after: [String: Any]) {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/QQPausedClockCI48")
        func read(_ name: String) throws -> [String: Any] {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            let value = try JSONSerialization.jsonObject(with: data)
            return try #require(value as? [String: Any])
        }
        return try (read("before.json"), read("after.json"))
    }

    @Test func actualCI48SourceCanRestoreTheWithheldPausedClock() throws {
        let (before, after) = try reports()
        let raw = try #require(after["currentMediaRemotePayload"] as? [String: Any])
        #expect(raw["playbackRate"] == nil) // Absent is not an observed explicit zero.
        #expect(LyricNativePlayerVerification.pausedClockRecoveryIsBackedBySource(
            before: before, after: after, player: .qqMusic, modelPositionMS: 64_000))
    }

    @Test func aReadbackCrossingTheSourceUpdateIsNotAConsistentBaseline() throws {
        let (before, after) = try reports()
        #expect(LyricNativePlayerVerification.pausedClockBaselineIsConsistent(before, player: .qqMusic, modelPositionMS: nil))
        #expect(!LyricNativePlayerVerification.pausedClockBaselineIsConsistent(after, player: .qqMusic, modelPositionMS: nil))
        #expect(!LyricNativePlayerVerification.pausedClockBaselineIsConsistent(before, player: .qqMusic, modelPositionMS: 64_000))
        #expect(LyricNativePlayerVerification.pausedClockBaselineIsConsistent(after, player: .qqMusic, modelPositionMS: 64_000))
    }

    @Test(arguments: ["sameTimestamp", "wrongPID", "positiveRate", "sameReceiptTime",
                      "differentSession", "differentGeneration", "differentProcess", "wrongPosition"])
    func rejectsUnsupportedRecovery(_ scenario: String) throws {
        let (before, originalAfter) = try reports()
        var after = originalAfter
        var raw = try #require(after["currentMediaRemotePayload"] as? [String: Any])
        let oldRaw = try #require(before["currentMediaRemotePayload"] as? [String: Any])
        var rows = try #require(after["players"] as? [[String: Any]])
        let oldRows = try #require(before["players"] as? [[String: Any]])
        var commands = try #require(after["commands"] as? [[String: Any]])
        var position: Int64 = 64_000
        switch scenario {
        case "sameTimestamp": raw["timestampEpochMicros"] = oldRaw["timestampEpochMicros"]
        case "wrongPID": raw["processIdentifier"] = -1
        case "positiveRate": raw["playbackRate"] = 1
        case "sameReceiptTime": rows[0]["observedUptimeNanoseconds"] = oldRows[0]["observedUptimeNanoseconds"]
        case "differentSession": commands[commands.count - 1]["sessionID"] = UUID().uuidString
        case "differentGeneration": commands[commands.count - 1]["generation"] = 999
        case "differentProcess": rows[0]["mediaProcessStartMicros"] = 1
        case "wrongPosition": position += 1
        default: Issue.record("Unknown regression case")
        }
        after["currentMediaRemotePayload"] = raw
        after["players"] = rows
        after["commands"] = commands
        #expect(!LyricNativePlayerVerification.pausedClockRecoveryIsBackedBySource(
            before: before, after: after, player: .qqMusic, modelPositionMS: position))
    }
}
