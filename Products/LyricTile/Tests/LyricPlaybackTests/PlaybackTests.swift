import Foundation
import Testing
import LyricCore
@testable import LyricPlayback

// Every payload in this file is a synthetic_fixture. These tests validate
// mechanisms; none constitutes player, TCC, macOS 27 or timing qualification.
private let testDomain = UUID(uuidString: "A6D09079-64FD-4B1A-A5BB-EE6344FF880A")!
private func stamp(_ milliseconds: UInt64 = 10_000) -> LyricDomain.MonotonicStamp {
    .init(nanoseconds: milliseconds * 1_000_000, clockDomainID: testDomain)
}
private func observation(player: PlayerID = .qqMusic, title: String = "Synthetic test A") -> PlayerObservation {
    .init(process: .init(player: player, pid: 123, startMicros: 98765, version: "fixture-1", build: "42"),
          mediaPID: 123, mediaProcessStart: 98765, title: title, artist: "Fixture Artist", album: nil,
          platformID: nil, durationMS: 180_000, positionMS: 20_000, state: .playing, rate: 1,
          stamp: stamp(), capabilities: .init(canPlay: true, canPause: true, canNext: true, canPrevious: true, canSeek: true),
          artwork: nil, artworkURL: nil, sourceIsCurrent: true)
}
private func data(_ text: String) -> Data { Data(text.utf8) }

@Test func exactMediaTimeUnitsAndUnknowns() throws {
    #expect(MediaTime.seconds(1.25) == 1250)
    #expect(MediaTime.micros(1_250_001) == 1250)
    #expect(try MediaTime.seekMicros(1250) == "1250000")
    #expect(MediaTime.seconds(nil) == nil)
    #expect(MediaTime.seconds(.nan) == nil)
    #expect(MediaTime.seconds(.infinity) == nil)
    #expect(MediaTime.seconds(-1) == nil)
    #expect(MediaTime.seconds(0) == 0)
    #expect(throws: PlaybackError.unsupported) { try MediaTime.seekMicros(Int64.max) }
}

@Test func fullDiffNullAndRestartAreDistinct() throws {
    var reducer = MediaRemoteReducer()
    #expect(throws: PlaybackError.malformedPayload) {
        try reducer.consume(data(#"{"type":"data","diff":true,"payload":{"playing":true}}"#))
    }
    try reducer.consume(data(#"{"type":"data","diff":false,"payload":{"title":"A","durationMicros":123000,"elapsedTimeMicros":0,"supportedCommands":[{"id":0,"enabled":true}]}}"#))
    try reducer.consume(data(#"{"type":"data","diff":true,"payload":{"elapsedTimeMicros":null,"playing":false}}"#))
    #expect(reducer.payload?["elapsedTimeMicros"] == nil)
    #expect(reducer.payload?["title"]?.string == "A")
    try reducer.consume(data(#"{"type":"data","diff":false,"payload":{"title":"B"}}"#))
    #expect(reducer.payload?["durationMicros"] == nil)
    #expect(reducer.payload?["supportedCommands"] == nil)
    reducer.reset()
    #expect(reducer.payload == nil)
}

@Test func ndjsonHandlesSplitUTF8AndRejectsUnboundedLine() throws {
    var framer = NDJSONFramer(limit: 32)
    let bytes = data("雪\nA\n")
    #expect(try framer.append(bytes.prefix(1)).isEmpty)
    let result = try framer.append(bytes.dropFirst())
    #expect(result == [data("雪"), data("A")])
    #expect(throws: PlaybackError.outputLimit) { try framer.append(Data(repeating: 65, count: 33)) }
}

private func remoteFields() -> [String: JSONValue] {
    ["bundleIdentifier": .string(PlayerID.qqMusic.bundleID), "processIdentifier": .int(123),
     "playing": .bool(true), "title": .string("Synthetic test A"), "durationMicros": .int(180_000_000),
     "elapsedTimeMicros": .int(30_000_000), "timestampEpochMicros": .int(100_000_000),
     "playbackRate": .double(1), "supportedCommands": .array([
        .object(["id": .int(0), "enabled": .bool(true)]), .object(["id": .int(1), "enabled": .bool(true)]),
        .object(["id": .int(4), "enabled": .bool(false)]), .object(["id": .int(24), "enabled": .bool(true)])])]
}

@Test func currentSourceAndExplicitCommandEvidenceAreRequired() {
    var fields = remoteFields()
    let payload = MediaRemotePayload(fields: fields)
    #expect(payload.capabilities(isCurrent: false) == TransportCapabilities())
    #expect(payload.capabilities(isCurrent: true).canPlay)
    #expect(!payload.capabilities(isCurrent: true).canNext)
    #expect(payload.capabilities(isCurrent: true).canSeek)
    fields["playing"] = .bool(false)
    #expect(!MediaRemotePayload(fields: fields).capabilities(isCurrent: true).canSeek)
    fields.removeValue(forKey: "supportedCommands")
    #expect(MediaRemotePayload(fields: fields).capabilities(isCurrent: true) == TransportCapabilities())
}

@Test func sourceTimestampRebaseUsesMicrosWithoutInventingMissingClock() throws {
    let process = observation().process
    var fields = remoteFields()
    let valid = try #require(MediaRemotePayload(fields: fields).observation(process: process, mediaStart: 98765,
        isCurrent: true, now: stamp(), wallNow: Date(timeIntervalSince1970: 107)))
    #expect(valid.positionMS == 37_000)
    #expect(valid.durationMS == 180_000)
    #expect(valid.expectedErrorMS == nil)
    #expect(valid.quality == .coarseSourceAnchor)
    fields.removeValue(forKey: "timestampEpochMicros")
    #expect(MediaRemotePayload(fields: fields).observation(process: process, mediaStart: 98765, isCurrent: true)?.positionMS == nil)
    fields["playing"] = .bool(false); fields["elapsedTimeMicros"] = .int(0)
    #expect(MediaRemotePayload(fields: fields).observation(process: process, mediaStart: 98765, isCurrent: true)?.positionMS == 0)
}

@Test func generationChangesOnlyForRecordingOrInstance() throws {
    var tracker = PlaybackSelectionTracker(); var first = observation()
    let a = try #require(tracker.update(first))
    first.positionMS = 100_000
    let sought = try #require(tracker.update(first))
    #expect(a.generation == sought.generation)
    first.album = "Late album metadata"; first.platformID = "late-source-id"
    let enriched = try #require(tracker.update(first))
    #expect(enriched.generation == a.generation)
    #expect(enriched.recording.fingerprint == a.recording.fingerprint)
    first.title = "Synthetic test B"; first.platformID = "different-source-id"
    let b = try #require(tracker.update(first))
    #expect(b.generation != a.generation)
    #expect(b.sessionID == a.sessionID)
    let restarted = PlayerObservation(process: .init(player: .qqMusic, pid: 123, startMicros: 99999, version: "fixture-1"),
        mediaPID: 123, mediaProcessStart: 99999, title: first.title, artist: first.artist, album: first.album,
        platformID: first.platformID, durationMS: first.durationMS, positionMS: 1, state: .playing, rate: 1,
        stamp: stamp(), capabilities: .init(), artwork: nil, artworkURL: nil, sourceIsCurrent: false)
    #expect(tracker.update(restarted)?.sessionID != b.sessionID)
}

@Test func routeRejectsGlobalOwnershipStaleClockAndWrongSelection() throws {
    var tracker = PlaybackSelectionTracker(); var value = observation()
    let selection = try #require(tracker.update(value))
    try TransportRoutePolicy.validate(.pause, expected: selection, current: selection, observation: value, now: stamp(10_100))
    value.sourceIsCurrent = false
    #expect(throws: PlaybackError.sourceNotCurrent) {
        try TransportRoutePolicy.validate(.pause, expected: selection, current: selection, observation: value, now: stamp(10_100))
    }
    value.sourceIsCurrent = true; value.quality = .stale
    #expect(throws: (any Error).self) {
        try TransportRoutePolicy.validate(.pause, expected: selection, current: selection, observation: value, now: stamp(10_100))
    }
    value.quality = .coarseSourceAnchor
    #expect(throws: PlaybackError.selectionChanged) {
        try TransportRoutePolicy.validate(.pause, expected: selection, current: nil, observation: value, now: stamp(10_100))
    }
    #expect(throws: PlaybackError.unsupported) {
        try TransportRoutePolicy.validate(.seek(milliseconds: 999_999), expected: selection, current: selection, observation: value, now: stamp(10_100))
    }
}

@Test func readbackRequiresActualDesiredStateAndPreservesPausedSeek() {
    let before = observation()
    var after = before; after.stamp = stamp(10_200)
    #expect(!CommandReadback.confirms(.pause, before: before, after: after, sentAt: stamp()))
    #expect(!CommandReadback.confirms(.next, before: before, after: after, sentAt: stamp()))
    after.state = .paused
    #expect(CommandReadback.confirms(.pause, before: before, after: after, sentAt: stamp()))
    var paused = before; paused.state = .paused
    after.positionMS = 50_000; after.state = .playing
    #expect(!CommandReadback.confirms(.seek(milliseconds: 50_000), before: paused, after: after, sentAt: stamp()))
    after.state = .paused
    #expect(CommandReadback.confirms(.seek(milliseconds: 50_000), before: paused, after: after, sentAt: stamp()))
    after.title = "Synthetic test B"
    #expect(CommandReadback.confirms(.next, before: before, after: after, sentAt: stamp()))
}

@Test func clockProfileNeverInventsCertification() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let value = observation()
    let valid = ClockQualificationRecord(player: .qqMusic, playerVersion: "fixture-1", playerBuild: "42", systemBuild: "fixture-os",
        adapterRevision: MediaRemoteClient.revision, dataOrigin: "real_player", referenceKind: "independent_position_reference",
        evidenceSHA256: String(repeating: "a", count: 64), measuredAt: now.addingTimeInterval(-100), expiresAt: now.addingTimeInterval(100),
        sampleCount: 100, recordingCount: 10, referenceUncertaintyMS: 50, positionErrorP95MS: 150)
    #expect(ClockQualifications().applying(to: value, systemBuild: "fixture-os", now: now).expectedErrorMS == nil)
    let store = ClockQualifications(records: [valid])
    #expect(store.applying(to: value, systemBuild: "fixture-os", now: now).expectedErrorMS == 150)
    #expect(store.applying(to: value, systemBuild: "new-os", now: now).quality == .coarseSourceAnchor)
    #expect(store.applying(to: value, systemBuild: "fixture-os", now: now.addingTimeInterval(101)).quality == .coarseSourceAnchor)
}

@Test func spotifyArtworkHasBoundedOfficialURLScope() {
    #expect(ArtworkLoader.allowedSpotifyURL(URL(string: "https://i.scdn.co/image/abc")!))
    #expect(!ArtworkLoader.allowedSpotifyURL(URL(string: "https://scdn.co.attacker.invalid/a")!))
    #expect(!ArtworkLoader.allowedSpotifyURL(URL(string: "file:///etc/passwd")!))
    #expect(!ArtworkLoader.allowedSpotifyURL(URL(string: "http://127.0.0.1/a")!))
}

@Test func processDrainsBothPipesWithoutDeadlock() async throws {
    let job = BoundedProcess(executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "i=0; while [ $i -lt 5000 ]; do printf abcdefghijklmnop; printf abcdefghijklmnop >&2; i=$((i+1)); done"],
        limit: 100_000, timeout: 5)
    let result = try await job.run()
    #expect(result.status == 0)
    #expect(result.data.count == 80_000)
    #expect(result.stderr.count == 64 * 1024)
}

@Test func processTimeoutReapsBusyChild() async throws {
    let job = BoundedProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "while :; do :; done"], limit: 1024, timeout: 0.1)
    await #expect(throws: PlaybackError.timeout) { try await job.run() }
}
