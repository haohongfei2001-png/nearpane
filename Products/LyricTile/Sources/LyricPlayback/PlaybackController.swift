import Foundation
import LyricCore

/// Four native-player adapters, source arbitration, real clock anchors and
/// readback-confirmed transport. It never publishes test media or starts audio.
public actor PlaybackController {
    private let apple = AppleEventClient()
    private let remote: MediaRemoteClient
    private let artworkLoader = ArtworkLoader()
    private var continuations: [UUID: AsyncStream<PlaybackSnapshot>.Continuation] = [:]
    private var snapshot: PlaybackSnapshot = .empty
    private var running = false
    private var sleeping = false
    private var lifecycle = UUID()
    private var observationEpoch: UInt64 = 0
    private var sourceRevision: UInt64 = 0
    private var preferred: PlayerID?
    private var loopTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var observer: PlaybackEnvironmentObserver?
    private var processes: [PlayerID: PlayerProcess] = [:]
    private var observations: [PlayerID: PlayerObservation] = [:]
    private var errors: [PlayerID: PlaybackError] = [:]
    private var due: [PlayerID: TimeInterval] = [:]
    private var lastPlayingTransition: [PlayerID: UInt64] = [:]
    private var transitionCounter: UInt64 = 0
    private var tracker = PlaybackSelectionTracker()
    private var currentSource: MediaRemotePayload?
    private var sourcePIDStart: UInt64 = 0
    private var currentReadDue: TimeInterval = 0
    private var streamRetryAt: TimeInterval = 0
    private var streamFailures = 0
    private var inTick = false
    private var commandBusy = false
    private var deniedCommands: Set<String> = []
    private var artworkAttempts: [String: TimeInterval] = [:]
    private var artworkRequest: String?
    private var artworkRequestID: UUID?
    private var qualifications = ClockQualifications()
    private var systemBuild = "unknown"
    private var commandTrace: [TransportTrace] = []

    public init() { remote = MediaRemoteClient() }
    // Inject only a local pinned helper layout for tests/development, never a command string.
    init(helperDirectory: URL) { remote = MediaRemoteClient(directory: helperDirectory) }

    public func updates() -> AsyncStream<PlaybackSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<PlaybackSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuations[id] = continuation; continuation.yield(snapshot)
        continuation.onTermination = { @Sendable [weak self] _ in Task { await self?.removeContinuation(id) } }
        return stream
    }
    private func removeContinuation(_ id: UUID) { continuations.removeValue(forKey: id) }

    public func start(preferred: PlayerID? = nil) async {
        if running { await select(preferred); return }
        running = true; sleeping = false; self.preferred = preferred; lifecycle = UUID()
        let epoch = lifecycle
        qualifications = ClockQualifications.load()
        systemBuild = await PlayerEnvironment.systemBuild()
        let newObserver = await PlaybackEnvironmentObserver { [weak self] signal in Task { await self?.signal(signal) } }
        guard running, lifecycle == epoch else { await newObserver.stop(); return }
        observer = newObserver
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                await self.tick(epoch: epoch)
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
    }
    public func stop() async {
        running = false; lifecycle = UUID()
        observationEpoch &+= 1; sourceRevision &+= 1
        let epoch = lifecycle
        let oldObserver = observer; observer = nil
        loopTask?.cancel(); loopTask = nil
        streamTask?.cancel(); streamTask = nil
        artworkTask?.cancel(); artworkTask = nil; artworkRequest = nil; artworkRequestID = nil
        processes.removeAll(); observations.removeAll(); errors.removeAll(); due.removeAll()
        currentSource = nil; sourcePIDStart = 0; tracker.clear(); deniedCommands.removeAll()
        lastPlayingTransition.removeAll(); artworkAttempts.removeAll(); currentReadDue = 0
        snapshot = .empty; publish(snapshot)
        await remote.stop(); await oldObserver?.stop(); await apple.release()
        if lifecycle == epoch && !running { await artworkLoader.clear() }
    }
    public func select(_ player: PlayerID?) async {
        preferred = player
        if let player { due[player] = 0 } else { for id in PlayerID.allCases { due[id] = 0 } }
        currentReadDue = 0
        await reconcile()
        if running { await tick(epoch: lifecycle) }
    }
    public func openPlayer(_ player: PlayerID) async { await PlayerEnvironment.open(player) }

    /// Explicit local diagnostic export. It contains real player metadata and
    /// observed command outcomes, no credentials and no synthetic success rows.
    /// The caller decides whether/where to save it; normal operation writes none.
    public func diagnosticReport() throws -> Data {
        let players = observations.values.map { value in
            DiagnosticPlayer(player: value.process.player.rawValue, bundleID: value.process.player.bundleID,
                pid: value.process.pid, processStartMicros: value.process.startMicros,
                mediaPID: value.mediaPID, mediaProcessStartMicros: value.mediaProcessStart,
                version: value.process.version, build: value.process.build,
                title: value.title, artist: value.artist, album: value.album, platformID: value.platformID,
                durationMS: value.durationMS, positionMS: value.positionMS, state: value.state.rawValue,
                observedUptimeNanoseconds: value.stamp.nanoseconds, quality: value.quality.rawValue,
                expectedErrorMS: value.expectedErrorMS, isCurrentSystemSource: value.sourceIsCurrent,
                capabilities: value.capabilities)
        }
        let report = PlaybackDiagnosticReport(dataOrigin: "real_player", exportedAt: Date(), systemBuild: systemBuild,
            appleEventsRevision: AppleEventClient.revision, mediaRemoteRevision: MediaRemoteClient.revision,
            selectedPlayer: snapshot.player?.rawValue, players: players,
            currentMediaRemotePayload: currentSource?.fields.filter { $0.key != "artworkData" }, commands: commandTrace)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }

    private func signal(_ signal: EnvironmentSignal) async {
        guard running else { return }
        switch signal {
        case .sleep:
            observationEpoch &+= 1
            sleeping = true; streamTask?.cancel(); streamTask = nil; await remote.stop()
            for id in observations.keys { observations[id]?.quality = .stale; observations[id]?.capabilities = .init() }
            await reconcile()
        case .wake:
            observationEpoch &+= 1
            sleeping = false; due.removeAll(); currentReadDue = 0; currentSource = nil; sourcePIDStart = 0
            streamRetryAt = 0; await tick(epoch: lifecycle)
        case .playersChanged, .playbackChanged:
            for id in PlayerID.allCases { due[id] = 0 }
            currentReadDue = 0; await tick(epoch: lifecycle)
        }
    }

    private func tick(epoch: UUID) async {
        guard running, lifecycle == epoch, !sleeping, !inTick, !commandBusy else { return }
        inTick = true; defer { inTick = false }
        let sampleEpoch = observationEpoch
        let discovered = await PlayerEnvironment.running()
        guard running, lifecycle == epoch, !sleeping, observationEpoch == sampleEpoch else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var found: [PlayerID: PlayerProcess] = [:]
        var ambiguous: Set<PlayerID> = []
        for process in discovered {
            // Multiple app instances are ambiguous; never silently select a PID.
            if found[process.player] != nil { ambiguous.insert(process.player); continue }
            found[process.player] = process
        }
        for id in ambiguous { found.removeValue(forKey: id); observations.removeValue(forKey: id) }
        for id in PlayerID.allCases where found[id] == nil {
            observations.removeValue(forKey: id); errors.removeValue(forKey: id); due.removeValue(forKey: id)
        }
        for (id, process) in found where processes[id] != process {
            observations.removeValue(forKey: id); due[id] = 0; errors.removeValue(forKey: id)
        }
        processes = found
        for id in ambiguous { errors[id] = .ambiguousSession }
        let hasRemote = found.keys.contains { !$0.usesAppleEvents }
        if hasRemote {
            if streamTask == nil, now >= streamRetryAt { beginStream(epoch: epoch) }
            if now >= currentReadDue {
                currentReadDue = now + 6
                do {
                    let value = try await remote.read().first
                    guard running, lifecycle == epoch, !sleeping, observationEpoch == sampleEpoch else { return }
                    await acceptCurrent(value)
                } catch {
                    await acceptCurrent(nil)
                    for id in found.keys where !id.usesAppleEvents { errors[id] = playbackError(error) }
                }
            }
        } else {
            streamTask?.cancel(); streamTask = nil; await remote.stop()
            currentSource = nil; sourcePIDStart = 0
        }
        for id in PlayerID.allCases {
            guard let process = found[id], now >= (due[id] ?? 0) else { continue }
            let selected = preferred == id || snapshot.player == id
            due[id] = now + (id.usesAppleEvents ? (selected ? (observations[id]?.state == .playing ? 1 : 3) : 5) : 6)
            do {
                let observation = try await read(process)
                guard running, lifecycle == epoch, !sleeping, observationEpoch == sampleEpoch, processes[id] == process else { return }
                accept(observation)
            } catch {
                errors[id] = playbackError(error)
                if errors[id] == .selectionChanged { observations.removeValue(forKey: id) }
                observations[id]?.quality = .stale; observations[id]?.capabilities = .init()
                // TCC denial is retried slowly; a real playback notification or
                // explicit source choice rechecks immediately after Settings changes.
                due[id] = now + (errors[id] == .authorizationDenied ? 15 : 4)
            }
        }
        guard running, lifecycle == epoch, !sleeping, observationEpoch == sampleEpoch else { return }
        expireOldObservations()
        await reconcile()
    }

    private func read(_ process: PlayerProcess, artwork: Bool = false, forceCurrent: Bool = false) async throws -> PlayerObservation {
        guard await PlayerEnvironment.processStart(process.pid) == process.startMicros, process.startMicros != 0 else { throw PlaybackError.playerExited }
        if process.player.usesAppleEvents {
            let result = try await apple.read(process, artwork: artwork)
            guard await PlayerEnvironment.processStart(process.pid) == process.startMicros else { throw PlaybackError.playerExited }
            return result
        }
        let values = try await remote.read(target: forceCurrent ? nil : process.player, artwork: artwork)
        let matches = values.filter { $0.player == process.player }
        let payload: MediaRemotePayload
        if matches.count == 1 { payload = matches[0] }
        else if matches.count > 1, let currentPID = currentSource?.pid,
                let exact = matches.first(where: { $0.pid == currentPID }), matches.filter({ $0.pid == currentPID }).count == 1 {
            payload = exact
        } else if matches.count > 1 { throw PlaybackError.ambiguousSession }
        else if forceCurrent { throw PlaybackError.sourceNotCurrent }
        else { throw PlaybackError.unavailable("播放器暂未提供媒体信息") }
        if forceCurrent { await acceptCurrent(payload) }
        guard let pid = payload.pid else { throw PlaybackError.malformedPayload }
        let start = await PlayerEnvironment.processStart(pid)
        guard await PlayerEnvironment.processStart(process.pid) == process.startMicros else { throw PlaybackError.playerExited }
        let isCurrent = payload.player == currentSource?.player && payload.pid == currentSource?.pid && start != 0 && start == sourcePIDStart
        guard let result = payload.observation(process: process, mediaStart: start, isCurrent: isCurrent) else { throw PlaybackError.malformedPayload }
        return result
    }

    private func accept(_ incoming: PlayerObservation) {
        let observation = qualifications.applying(to: incoming, systemBuild: systemBuild)
        let id = observation.process.player
        if observation.state == .playing && observations[id]?.state != .playing {
            transitionCounter &+= 1; lastPlayingTransition[id] = transitionCounter
        }
        observations[id] = observation; errors.removeValue(forKey: id)
    }
    private func acceptCurrent(_ payload: MediaRemotePayload?) async {
        sourceRevision &+= 1
        let revision = sourceRevision
        let start: UInt64
        if let pid = payload?.pid { start = await PlayerEnvironment.processStart(pid) } else { start = 0 }
        guard revision == sourceRevision else { return }
        currentSource = payload; sourcePIDStart = start
        for id in observations.keys where !id.usesAppleEvents {
            guard var observation = observations[id] else { continue }
            let current = payload?.player == id && payload?.pid == observation.mediaPID && sourcePIDStart == observation.mediaProcessStart && sourcePIDStart != 0
            observation.sourceIsCurrent = current
            observation.capabilities = current ? (payload?.capabilities(isCurrent: true) ?? .init()) : .init()
            observations[id] = observation
        }
    }
    private func beginStream(epoch: UUID) {
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                let bytes = try await self.remote.stream()
                var framer = NDJSONFramer(); var reducer = MediaRemoteReducer()
                for try await chunk in bytes {
                    try Task.checkCancellation()
                    for line in try framer.append(chunk) {
                        if let fields = try reducer.consume(line) { await self.streamUpdate(MediaRemotePayload(fields: fields), epoch: epoch) }
                    }
                }
            } catch {
                if !Task.isCancelled { await self.streamEnded(error, epoch: epoch) }
            }
        }
    }
    private func streamUpdate(_ payload: MediaRemotePayload, epoch: UUID) async {
        guard running, lifecycle == epoch, !sleeping else { return }
        streamFailures = 0
        await acceptCurrent(payload)
        if let id = payload.player, !id.usesAppleEvents, let process = processes[id],
           let observation = payload.observation(process: process, mediaStart: sourcePIDStart, isCurrent: sourcePIDStart != 0) {
            accept(observation)
        }
        await reconcile()
    }
    private func streamEnded(_ error: any Error, epoch: UUID) async {
        guard running, lifecycle == epoch else { return }
        streamTask = nil; streamFailures = min(streamFailures + 1, 6)
        streamRetryAt = ProcessInfo.processInfo.systemUptime + min(30, pow(2, Double(streamFailures)))
        for id in processes.keys where !id.usesAppleEvents { errors[id] = playbackError(error) }
        // Health snapshots can still work while the event stream reconnects.
        currentReadDue = 0
    }
    private func expireOldObservations() {
        let now = PlaybackClock.now()
        for id in observations.keys {
            guard let old = observations[id] else { continue }
            if now.clockDomainID != old.stamp.clockDomainID || now.nanoseconds < old.stamp.nanoseconds || now.nanoseconds - old.stamp.nanoseconds > 12_000_000_000 {
                observations[id]?.quality = .stale; observations[id]?.capabilities = .init()
            }
        }
    }
    private func chosenPlayer() -> PlayerID? {
        if let preferred { return preferred }
        let playing = observations.values.filter { $0.state == .playing && $0.quality != .stale }
        if let freshest = playing.max(by: { (lastPlayingTransition[$0.process.player] ?? 0) < (lastPlayingTransition[$1.process.player] ?? 0) }) {
            return freshest.process.player
        }
        if let id = snapshot.player, processes[id] != nil { return id }
        return PlayerID.allCases.first { observations[$0]?.hasRecording == true } ?? PlayerID.allCases.first { processes[$0] != nil }
    }
    private func reconcile() async {
        guard running else { return }
        let epoch = lifecycle
        guard let chosen = chosenPlayer() else {
            tracker.clear(); publish(.empty); return
        }
        guard let observation = observations[chosen] else {
            tracker.clear()
            publish(PlaybackSnapshot(player: chosen, selection: nil, anchor: nil, state: .unknown,
                statusMessage: errors[chosen]?.localizedDescription ?? (processes[chosen] == nil ? "打开 \(chosen.displayName) 开始播放" : "正在连接播放器"),
                requiresAuthorization: errors[chosen] == .authorizationDenied)); return
        }
        let previous = tracker.selection
        let selection = tracker.update(observation)
        if selection?.generation != previous?.generation || selection?.sessionID != previous?.sessionID {
            deniedCommands.removeAll(); artworkTask?.cancel(); artworkTask = nil; artworkRequest = nil
        }
        var capabilities = observation.capabilities
        if deniedCommands.contains("play") { capabilities.canPlay = false }
        if deniedCommands.contains("pause") { capabilities.canPause = false }
        if deniedCommands.contains("next") { capabilities.canNext = false }
        if deniedCommands.contains("previous") { capabilities.canPrevious = false }
        if deniedCommands.contains("seek") { capabilities.canSeek = false }
        if observation.quality == .stale || sleeping { capabilities = .init() }
        let anchor = selection.map { LyricDomain.PlaybackAnchor(selection: $0, positionMS: observation.positionMS,
            observedAt: observation.stamp, playbackRate: observation.rate, state: observation.state,
            quality: sleeping ? .stale : observation.quality, expectedErrorMS: observation.expectedErrorMS) }
        let cover: Data?
        if let selection { cover = await artworkLoader.cached(selection.recording.fingerprint) } else { cover = nil }
        // Reentrancy: a newer selection may have arrived while reading the cache.
        guard running, lifecycle == epoch, tracker.selection?.sessionID == selection?.sessionID, tracker.selection?.generation == selection?.generation else { return }
        let message: String?
        if observation.quality == .stale || sleeping { message = "重新连接播放器" }
        else if observation.positionMS == nil && selection != nil { message = "播放器不提供进度" }
        else { message = nil }
        publish(PlaybackSnapshot(player: chosen, selection: selection, anchor: anchor, state: observation.state,
            capabilities: capabilities, artwork: cover ?? observation.artwork, statusMessage: message,
            requiresAuthorization: errors[chosen] == .authorizationDenied))
        if let selection, cover == nil { requestArtwork(observation, selection: selection) }
    }
    private func publish(_ value: PlaybackSnapshot) {
        snapshot = value
        for continuation in continuations.values { continuation.yield(value) }
    }
    private func requestArtwork(_ observation: PlayerObservation, selection: LyricDomain.Selection) {
        let key = selection.recording.fingerprint
        let now = ProcessInfo.processInfo.systemUptime
        guard artworkRequest != key, now >= (artworkAttempts[key] ?? 0) else { return }
        if artworkAttempts.count > 128 { artworkAttempts.removeAll() }
        artworkAttempts[key] = now + 30; artworkRequest = key
        let requestID = UUID(); artworkRequestID = requestID
        let epoch = lifecycle
        artworkTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data: Data?
                if let existing = observation.artwork { data = existing }
                else if observation.process.player == .spotify, let url = observation.artworkURL {
                    data = try await self.artworkLoader.downloadSpotify(url)
                } else {
                    let fresh = try await self.read(observation.process, artwork: true)
                    guard PlaybackSelectionTracker.sameRecording(observation, fresh) else { throw PlaybackError.selectionChanged }
                    data = fresh.artwork
                }
                try Task.checkCancellation()
                if let data { await self.artworkReady(data, selection: selection, epoch: epoch) }
            } catch { /* Cover absence must not replace valid lyrics with an error. */ }
            await self.finishArtwork(key: key, requestID: requestID)
        }
    }
    private func finishArtwork(key: String, requestID: UUID) {
        if artworkRequest == key && artworkRequestID == requestID { artworkRequest = nil; artworkRequestID = nil; artworkTask = nil }
    }
    private func artworkReady(_ data: Data, selection: LyricDomain.Selection, epoch: UUID) async {
        guard running, lifecycle == epoch, PlaybackSelectionTracker.matches(tracker.selection, selection) else { return }
        await artworkLoader.insert(data, key: selection.recording.fingerprint)
        guard PlaybackSelectionTracker.matches(tracker.selection, selection) else { return }
        await reconcile()
    }

    public func perform(_ command: TransportCommand, expected: LyricDomain.Selection) async throws {
        let traceID = UUID(); let began = PlaybackClock.now()
        let ownerBefore = currentSource?.fields["bundleIdentifier"]?.string
        let ownerPIDBefore = currentSource?.pid
        var traceOutcome = "rejected_before_dispatch"
        defer {
            commandTrace.append(TransportTrace(id: traceID, intent: command.name,
                seekMS: { if case .seek(let ms) = command { return ms }; return nil }(),
                targetBundleID: expected.playerBundleID, sessionID: expected.sessionID, generation: expected.generation,
                startedUptimeNanoseconds: began.nanoseconds, finishedUptimeNanoseconds: PlaybackClock.now().nanoseconds,
                observedSystemOwnerBefore: ownerBefore, observedSystemPIDBefore: ownerPIDBefore,
                observedSystemOwnerAfter: currentSource?.fields["bundleIdentifier"]?.string,
                observedSystemPIDAfter: currentSource?.pid, outcome: traceOutcome))
            if commandTrace.count > 64 { commandTrace.removeFirst(commandTrace.count - 64) }
        }
        guard running, !sleeping else { throw PlaybackError.unavailable("播放器连接未运行") }
        guard !commandBusy else { throw PlaybackError.commandInProgress }
        guard PlaybackSelectionTracker.matches(snapshot.selection, expected), let id = snapshot.player,
              let process = processes[id] else { throw PlaybackError.selectionChanged }
        guard snapshot.capabilities.allows(command) else { throw PlaybackError.unsupported }
        commandBusy = true; defer { commandBusy = false }
        let epoch = lifecycle
        let sampleEpoch = observationEpoch
        // MR read(target:) does not target commands. Require a fresh global read
        // and the selected native process identity immediately before dispatch.
        let before = try await read(process, forceCurrent: !id.usesAppleEvents)
        guard running, lifecycle == epoch, !sleeping, observationEpoch == sampleEpoch, PlaybackSelectionTracker.matches(tracker.selection, expected) else { throw PlaybackError.selectionChanged }
        if let prior = observations[id], !PlaybackSelectionTracker.sameRecording(prior, before) {
            accept(before); await reconcile(); throw PlaybackError.selectionChanged
        }
        accept(before); await reconcile()
        try TransportRoutePolicy.validate(command, expected: expected, current: tracker.selection, observation: before)
        guard !deniedCommands.contains(command.name) else { throw PlaybackError.unsupported }
        let sentAt = PlaybackClock.now()
        traceOutcome = "dispatch_attempted_unconfirmed"
        if id.usesAppleEvents { try await apple.send(command, to: process) }
        else { try await remote.send(command) }
        var lastFailure: PlaybackError = .notConfirmed("尚未读到目标状态")
        // Commands are sent once. Repeated reads are safe; previous/next retries are not.
        for delay in [120, 250, 400, 650] {
            try await Task.sleep(for: .milliseconds(delay))
            guard running, lifecycle == epoch, !sleeping, observationEpoch == sampleEpoch else { throw CancellationError() }
            do {
                let after = try await read(process, forceCurrent: !id.usesAppleEvents)
                guard running, lifecycle == epoch, !sleeping, observationEpoch == sampleEpoch else { throw CancellationError() }
                let stillSelected = snapshot.player == id && snapshot.selection?.sessionID == expected.sessionID
                guard stillSelected else { throw PlaybackError.selectionChanged }
                accept(after); await reconcile()
                if CommandReadback.confirms(command, before: before, after: after, sentAt: sentAt) {
                    traceOutcome = "readback_confirmed"; return
                }
                if before.state == .paused && after.state == .playing, case .seek = command {
                    lastFailure = .notConfirmed("跳转使播放器恢复播放；暂停中跳转已停用")
                    break
                }
            } catch let error as PlaybackError {
                lastFailure = error
                if error == .sourceNotCurrent || error == .selectionChanged || error == .playerExited { throw error }
            }
        }
        if PlaybackSelectionTracker.matches(tracker.selection, expected) { deniedCommands.insert(command.name); await reconcile() }
        throw lastFailure
    }
    private func playbackError(_ error: any Error) -> PlaybackError {
        (error as? PlaybackError) ?? .unavailable(error.localizedDescription)
    }
}
