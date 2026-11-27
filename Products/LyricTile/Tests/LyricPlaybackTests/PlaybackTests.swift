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

@Test func noCurrentMediaIsAValidEmptyGetNotCorruptProtocol() throws {
    #expect(try MediaRemotePayload.decodeGet(data("null"), target: nil).isEmpty)
    #expect(try MediaRemotePayload.decodeGet(data("[]"), target: .qqMusic).isEmpty)
    #expect(JSONValue.double(1_800_000_000_000_000).integer == 1_800_000_000_000_000)
    #expect(JSONValue.double(1.5).integer == nil)
}

@Test func ndjsonHandlesSplitUTF8AndRejectsUnboundedLine() throws {
    var framer = NDJSONFramer(limit: 32)
    let bytes = data("雪\nA\n")
    let initialLines = try framer.append(bytes.prefix(1))
    #expect(initialLines.isEmpty)
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
    fields["playing"] = .bool(true); fields.removeValue(forKey: "elapsedTimeMicros")
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

@Test func wallClockJumpAndWakeRequireANewRemoteSourceAnchor() {
    var continuity = RemoteClockContinuity()
    let initial = continuity.accepts(sourceTimestampMicros: 100_000_000, state: .playing,
                                    now: stamp(10_000), wall: Date(timeIntervalSince1970: 100))
    let stable = continuity.accepts(sourceTimestampMicros: 100_000_000, state: .playing,
                                   now: stamp(11_000), wall: Date(timeIntervalSince1970: 101))
    let jumped = continuity.accepts(sourceTimestampMicros: 100_000_000, state: .playing,
                                   now: stamp(12_000), wall: Date(timeIntervalSince1970: 401))
    let oldAgain = continuity.accepts(sourceTimestampMicros: 100_000_000, state: .playing,
                                     now: stamp(13_000), wall: Date(timeIntervalSince1970: 402))
    let fresh = continuity.accepts(sourceTimestampMicros: 402_000_000, state: .playing,
                                  now: stamp(13_050), wall: Date(timeIntervalSince1970: 402.05))
    #expect(initial && stable)
    #expect(!jumped && !oldAgain)
    #expect(fresh)
    continuity.invalidate(wall: Date(timeIntervalSince1970: 403))
    let wakeOld = continuity.accepts(sourceTimestampMicros: 402_000_000, state: .playing,
                                    now: stamp(14_000), wall: Date(timeIntervalSince1970: 403))
    #expect(!wakeOld)
}

@Test func generationChangesOnlyForRecordingOrInstance() throws {
    var tracker = PlaybackSelectionTracker(); var first = observation()
    let initialSelection = tracker.update(first)
    let a = try #require(initialSelection)
    first.positionMS = 100_000
    let seekSelection = tracker.update(first)
    let sought = try #require(seekSelection)
    #expect(a.generation == sought.generation)
    first.album = "Late album metadata"; first.platformID = "late-source-id"
    let enrichedSelection = tracker.update(first)
    let enriched = try #require(enrichedSelection)
    #expect(enriched.generation == a.generation)
    #expect(enriched.recording.fingerprint == a.recording.fingerprint)
    first.title = "Synthetic test B"; first.platformID = "different-source-id"
    let changedSelection = tracker.update(first)
    let b = try #require(changedSelection)
    #expect(b.generation != a.generation)
    #expect(b.sessionID == a.sessionID)
    let restarted = PlayerObservation(process: .init(player: .qqMusic, pid: 123, startMicros: 99999, version: "fixture-1"),
        mediaPID: 123, mediaProcessStart: 99999, title: first.title, artist: first.artist, album: first.album,
        platformID: first.platformID, durationMS: first.durationMS, positionMS: 1, state: .playing, rate: 1,
        stamp: stamp(), capabilities: .init(), artwork: nil, artworkURL: nil, sourceIsCurrent: false)
    let restartedSelection = tracker.update(restarted)
    #expect(restartedSelection?.sessionID != b.sessionID)
}

@Test func sparseMetadataRetainsIdentityUntilAConflictingRecordingArrives() throws {
    let omittedIDs: [String?] = [nil, ""]
    for omittedID in omittedIDs {
        var tracker = PlaybackSelectionTracker(); var first = observation()
        first.platformID = "fixture-track-a"; first.album = "Fixture album A"
        let initialValue = tracker.update(first)
        let initial = try #require(initialValue)
        var sparse = first
        sparse.platformID = omittedID; sparse.artist = nil; sparse.album = nil; sparse.durationMS = nil
        let retainedValue = tracker.update(sparse)
        let retained = try #require(retainedValue)
        #expect(retained.generation == initial.generation)
        #expect(retained.recording == initial.recording)
        // Equal titles do not make two different platform recordings identical.
        sparse.platformID = "fixture-track-b"
        let changedValue = tracker.update(sparse)
        let changed = try #require(changedValue)
        #expect(changed.generation != initial.generation)
        #expect(changed.recording.fingerprint != initial.recording.fingerprint)
        #expect(changed.recording.album == nil)
    }
}

@Test func sparseMetadataRetainsTitleAndMetadataOnlyIdentity() throws {
    var tracker = PlaybackSelectionTracker(); var first = observation()
    first.album = "Fixture album A"
    let initialValue = tracker.update(first)
    let initial = try #require(initialValue)
    var sparse = first; sparse.album = nil
    let missingAlbum = tracker.update(sparse)
    #expect(missingAlbum?.generation == initial.generation)
    sparse.album = "Fixture album B"
    let changedAlbum = tracker.update(sparse)
    #expect(changedAlbum?.generation != initial.generation)
    sparse.platformID = "fixture-track-b"
    let identifiedValue = tracker.update(sparse)
    let identified = try #require(identifiedValue)
    sparse.title = nil
    let missingTitleValue = tracker.update(sparse)
    let missingTitle = try #require(missingTitleValue)
    #expect(missingTitle.generation == identified.generation)
    #expect(missingTitle.recording.title == identified.recording.title)
    sparse.platformID = nil
    let empty = tracker.update(sparse)
    #expect(empty == nil)
}

@Test func emptyPlatformIDsDoNotCollapseDifferentRecordingFingerprints() throws {
    var tracker = PlaybackSelectionTracker(); var value = observation()
    value.platformID = ""
    let firstValue = tracker.update(value)
    let first = try #require(firstValue)
    value.title = "Synthetic test B"
    let nextValue = tracker.update(value)
    let next = try #require(nextValue)
    #expect(next.recording.fingerprint != first.recording.fingerprint)
    #expect(first.recording.platformIDs.isEmpty)
    #expect(next.recording.platformIDs.isEmpty)
}

@Test func restartedMediaProcessCreatesANewSourceSession() throws {
    var tracker = PlaybackSelectionTracker(); var value = observation()
    let firstValue = tracker.update(value)
    let first = try #require(firstValue)
    value.mediaProcessStart += 1
    let restartedValue = tracker.update(value)
    let restarted = try #require(restartedValue)
    #expect(restarted.sessionID != first.sessionID)
    #expect(restarted.generation != first.generation)
    value.mediaPID += 1
    let replacedValue = tracker.update(value)
    let replaced = try #require(replacedValue)
    #expect(replaced.sessionID != restarted.sessionID)
}

@Test func routeRejectsGlobalOwnershipStaleClockAndWrongSelection() throws {
    var tracker = PlaybackSelectionTracker(); var value = observation()
    let updatedSelection = tracker.update(value)
    let selection = try #require(updatedSelection)
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

@Test func readbackRejectsOldObservationsAndLostGlobalOwnership() {
    let before = observation()
    var after = before; after.state = .paused; after.stamp = stamp(9_999)
    #expect(!CommandReadback.confirms(.pause, before: before, after: after, sentAt: stamp()))
    after.stamp = .init(nanoseconds: stamp(10_200).nanoseconds, clockDomainID: UUID())
    #expect(!CommandReadback.confirms(.pause, before: before, after: after, sentAt: stamp()))
    after.stamp = stamp(10_200); after.quality = .stale
    #expect(!CommandReadback.confirms(.pause, before: before, after: after, sentAt: stamp()))
    after.quality = .unavailable; after.positionMS = nil
    #expect(CommandReadback.confirms(.pause, before: before, after: after, sentAt: stamp()))
    after.sourceIsCurrent = false
    #expect(!CommandReadback.confirms(.pause, before: before, after: after, sentAt: stamp()))
    let nativeBefore = observation(player: .appleMusic)
    var nativeAfter = nativeBefore; nativeAfter.state = .paused
    nativeAfter.stamp = stamp(10_200); nativeAfter.sourceIsCurrent = false
    #expect(CommandReadback.confirms(.pause, before: nativeBefore, after: nativeAfter, sentAt: stamp()))
}

@Test func seekReadbackUsesObservedRateAndTrackEnd() {
    let before = observation()
    var faster = before; faster.stamp = stamp(14_000); faster.rate = 2; faster.positionMS = 58_000
    #expect(CommandReadback.confirms(.seek(milliseconds: 50_000), before: before, after: faster, sentAt: stamp()))
    faster.positionMS = 70_000
    #expect(!CommandReadback.confirms(.seek(milliseconds: 50_000), before: before, after: faster, sentAt: stamp()))
    let nativeBefore = observation(player: .appleMusic)
    var ended = nativeBefore; ended.stamp = stamp(12_000); ended.positionMS = 180_000
    #expect(CommandReadback.confirms(.seek(milliseconds: 179_500), before: nativeBefore, after: ended, sentAt: stamp()))
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

@Test func sourceArbitrationDoesNotMistakePollingOrderForUserIntent() {
    let samples: [PlayerID: PlayerObservation] = [.appleMusic: observation(player: .appleMusic), .spotify: observation(player: .spotify)]
    let available: Set<PlayerID> = [.appleMusic, .spotify]
    #expect(PlaybackSourcePolicy.choose(preferred: nil, previous: .spotify, currentSource: nil,
        observations: samples, available: available, transitions: [:]) == .spotify)
    #expect(PlaybackSourcePolicy.choose(preferred: nil, previous: .spotify, currentSource: .appleMusic,
        observations: samples, available: available, transitions: [:]) == .appleMusic)
    #expect(PlaybackSourcePolicy.choose(preferred: .qqMusic, previous: .spotify, currentSource: .appleMusic,
        observations: samples, available: available, transitions: [:]) == .qqMusic)
    #expect(PlaybackSourcePolicy.choose(preferred: nil, previous: .appleMusic, currentSource: nil,
        observations: samples, available: available, transitions: [.spotify: 1]) == .spotify)
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

@Test func explicitDiagnosticCollectionRejectsInvalidDurationWithoutProbing() async {
    await #expect(throws: DiagnosticCollectionError.self) {
        try await PlaybackController.collectDiagnostics(seconds: 0, outputDirectory: URL(fileURLWithPath: "/unused-fixture-output"))
    }
}

@Test func explicitDiagnosticCollectionNeverOverwritesExistingOutput() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LyricTile-fixture-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("keep.txt")
    try data("fixture-must-remain").write(to: marker)
    await #expect(throws: DiagnosticCollectionError.self) {
        try await PlaybackController.collectDiagnostics(player: .appleMusic, seconds: 1, outputDirectory: directory)
    }
    #expect(try Data(contentsOf: marker) == data("fixture-must-remain"))
}


@Test func qqTransientContentUUIDCannotConfirmSkipOrInvalidateLocalBinding() throws {
    let process = PlayerProcess(player: .qqMusic, pid: 123, startMicros: 1, version: "11.11.0", build: "73284")
    var fields = remoteFields()
    func scopedObservation() throws -> PlayerObservation {
        try #require(MediaRemotePayload(fields: fields).observation(process: process, mediaStart: 1, isCurrent: true))
    }
    fields["contentItemIdentifier"] = .string(UUID().uuidString)
    let first = try scopedObservation()
    fields["contentItemIdentifier"] = .string(UUID().uuidString)
    let resumed = try scopedObservation()
    #expect(first.platformID == nil)
    #expect(PlaybackSelectionTracker.sameRecording(first, resumed))
    #expect(!CommandReadback.confirms(.next, before: first, after: resumed, sentAt: first.stamp))
    fields["title"] = .string("Another fixture")
    #expect(!PlaybackSelectionTracker.sameRecording(first, try scopedObservation()))
    fields["contentItemIdentifier"] = .string("catalog-track-123")
    #expect(try scopedObservation().platformID == "catalog-track-123")
    fields["playing"] = .bool(false)
    #expect(try scopedObservation().positionMS == nil)
    #expect(try scopedObservation().clockNeedsReanchor)
    fields["playbackRate"] = .double(0)
    #expect(try scopedObservation().positionMS == 30_000)
}

@Test func qqKnownBuildsKeepLocalBindingIdentityAcrossSeekAndResumeUUIDs() throws {
    for (version, build) in [("11.11.0", "73284"), ("11.11.1", "73285")] {
        let process = PlayerProcess(player: .qqMusic, pid: 123, startMicros: 1, version: version, build: build)
        var fields = remoteFields()
        fields["artist"] = .string("Fixture Artist")
        fields["album"] = .string("Fixture Album")
        fields["contentItemIdentifier"] = .string("00000000-0000-4000-8000-000000000001")
        func sample(_ milliseconds: UInt64, wall: Double) throws -> PlayerObservation {
            try #require(MediaRemotePayload(fields: fields).observation(process: process, mediaStart: 1,
                isCurrent: true, now: stamp(milliseconds), wallNow: Date(timeIntervalSince1970: wall)))
        }
        let before = try sample(10_000, wall: 100)
        var tracker = PlaybackSelectionTracker()
        let initialValue = tracker.update(before)
        let initial = try #require(initialValue)
        fields["contentItemIdentifier"] = .string("00000000-0000-4000-8000-000000000002")
        fields["elapsedTimeMicros"] = .int(64_000_000)
        fields["timestampEpochMicros"] = .int(101_000_000)
        let afterSeek = try sample(11_000, wall: 101)
        let soughtValue = tracker.update(afterSeek)
        let sought = try #require(soughtValue)
        #expect(sought.generation == initial.generation)
        #expect(sought.sessionID == initial.sessionID)
        #expect(sought.recording == initial.recording)
        #expect(sought.recording.platformIDs.isEmpty)
        #expect(CommandReadback.confirms(.seek(milliseconds: 64_000), before: before,
            after: afterSeek, sentAt: stamp(11_000)))
        #expect(!CommandReadback.confirms(.next, before: before, after: afterSeek, sentAt: stamp(11_000)))

        fields["playing"] = .bool(false); fields["playbackRate"] = .double(0)
        let pauseObservation = try sample(12_000, wall: 102)
        let pausedValue = tracker.update(pauseObservation)
        let paused = try #require(pausedValue)
        fields["contentItemIdentifier"] = .string("00000000-0000-4000-8000-000000000003")
        fields["playing"] = .bool(true); fields["playbackRate"] = .double(1)
        fields["timestampEpochMicros"] = .int(103_000_000)
        let resumeObservation = try sample(13_000, wall: 103)
        let resumedValue = tracker.update(resumeObservation)
        let resumed = try #require(resumedValue)
        #expect(paused.recording == initial.recording)
        #expect(resumed.generation == initial.generation)
        #expect(resumed.recording == initial.recording)
    }
}

@Test func qqUUIDNormalizationPreservesDifferentSongsVersionsAndCatalogIDs() throws {
    let process = PlayerProcess(player: .qqMusic, pid: 123, startMicros: 1, version: "11.11.1", build: "73285")
    var baseline = remoteFields()
    baseline["artist"] = .string("Fixture Artist")
    baseline["album"] = .string("Fixture Album")
    baseline["contentItemIdentifier"] = .string("00000000-0000-4000-8000-000000000001")
    func sample(_ fields: [String: JSONValue], process: PlayerProcess) throws -> PlayerObservation {
        try #require(MediaRemotePayload(fields: fields).observation(process: process, mediaStart: 1,
            isCurrent: true, now: stamp(), wallNow: Date(timeIntervalSince1970: 100)))
    }
    let original = try sample(baseline, process: process)
    let differences: [(String, JSONValue)] = [("title", .string("Synthetic test B")),
        ("title", .string("Synthetic test A (Live)")), ("artist", .string("Another Fixture Artist")),
        ("album", .string("Fixture Album (Remastered)")), ("durationMicros", .int(185_000_000))]
    for (key, value) in differences {
        var changed = baseline
        changed["contentItemIdentifier"] = .string("00000000-0000-4000-8000-000000000002")
        changed[key] = value
        let next = try sample(changed, process: process)
        var tracker = PlaybackSelectionTracker()
        let firstValue = tracker.update(original)
        let first = try #require(firstValue)
        let secondValue = tracker.update(next)
        let second = try #require(secondValue)
        #expect(second.generation != first.generation)
        #expect(second.recording.fingerprint != first.recording.fingerprint)
    }
    baseline["contentItemIdentifier"] = .string("catalog-recording-a")
    let catalogA = try sample(baseline, process: process)
    baseline["contentItemIdentifier"] = .string("catalog-recording-b")
    let catalogB = try sample(baseline, process: process)
    #expect(catalogA.platformID == "catalog-recording-a")
    #expect(catalogB.platformID == "catalog-recording-b")
    #expect(!PlaybackSelectionTracker.sameRecording(catalogA, catalogB))

    let unknown = PlayerProcess(player: .qqMusic, pid: 123, startMicros: 1, version: "fixture-unqualified", build: "unknown")
    let uuid = "00000000-0000-4000-8000-000000000001"
    baseline["contentItemIdentifier"] = .string(uuid)
    #expect(try sample(baseline, process: unknown).platformID == uuid)
    baseline["uniqueIdentifier"] = .string("stable-catalog-id")
    #expect(try sample(baseline, process: process).platformID == "stable-catalog-id")
}
