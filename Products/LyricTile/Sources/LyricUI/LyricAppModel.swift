import AppKit
import Combine
import Foundation
import LyricCore
import LyricPlayback
import LyricServices
import TileKit
import UniformTypeIdentifiers

@MainActor
public final class LyricAppModel: ObservableObject {
    @Published public private(set) var snapshot: PlaybackSnapshot = .empty
    @Published public private(set) var document: LyricDomain.Document? { didSet { rebuildLeadCues() } }
    @Published public private(set) var frame = LyricDomain.Frame(selection: nil, phase: .noPlayback, playbackState: .stopped, lookupMS: nil, presentedCues: [])
    @Published public private(set) var candidates: [LyricDomain.Candidate] = []
    @Published public private(set) var isResolving = false
    @Published public private(set) var isSearchingCandidates = false
    @Published public private(set) var isPerformingCommand = false
    @Published public private(set) var isSavingAdjustment = false
    @Published public private(set) var ownsSession = false
    @Published public private(set) var ownershipMessage: String?
    @Published public private(set) var artwork: NSImage?
    @Published public private(set) var advanceMS: Int64 = 0
    @Published public private(set) var playbackPositionMS: Int64?
    @Published public var actionMessage: String?
    @Published public var lyricFailure: String?
    @Published public var presentation: LyricAuxiliaryPage?
    @Published public var controlsVisible = false
    /// Actual pointer/keyboard interaction, separate from accessibility's always-visible controls.
    @Published public var panelInteractionActive = false
    @Published public var songMenuIsOpen = false
    @Published public var isVisible = false { didSet { if oldValue != isVisible { restartTimeline() } } }
    @Published public var seekPreviewMS: Int64?
    @Published public private(set) var browsedCueIndex: Int?
    @Published public var settings: LyricSettings { didSet { settingsChanged(from: oldValue) } }

    public var requestShowPanel: (@MainActor () -> Void)?
    public var requestHidePanel: (@MainActor () -> Void)?
    public var requestReposition: (@MainActor () -> Void)?
    public var requestUpdateCheck: (@MainActor () -> Void)?

    private let playback: PlaybackController
    private let repository: LyricRepository
    private let timeline = LyricTimeline()
    private let artworkDecoder = LyricArtworkDecoder()
    private let lease: TileSessionLease
    private let defaults: UserDefaults
    private var adjustment: LyricDomain.UserTimingAdjustment?
    private var seekSelection: LyricDomain.Selection?
    private var updateTask: Task<Void, Never>?
    private(set) var lyricTask: Task<Void, Never>?
    private(set) var candidateTask: Task<Void, Never>?
    private(set) var adjustmentTask: Task<Void, Never>?
    private var importPanel: NSOpenPanel?
    private var lyricRequestID = UUID()
    private var candidateRequestID = UUID()
    private var adjustmentRequestID = UUID()
    private enum LyricRequestKind { case automatic, candidate, localImport }
    private var lyricRequestKind = LyricRequestKind.automatic
    private var timelineTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var browseTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var startBarrier: Task<Bool, Never>?
    private var stopBarrier: Task<Void, Never>?
    private var runID = UUID()
    private var stopping = false
    private var lastArtworkData: Data?
    private var artworkToken = UUID()
    private var leadCueCache: [LyricDomain.Cue] = []
    // Keep controls under the pointer while a paused song receives its lyrics.
    // This is presentation-only: the repository result is still accepted normally.
    var pausedPanelContent: LyricPanelContent?

    public convenience init(storageURL: URL? = nil, defaults: UserDefaults = .standard) {
        let settings = LyricSettings.load(from: defaults)
        let directory = storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HOLDSNOW/LyricTile", isDirectory: true)
        self.init(repository: LyricRepository(storageURL: directory, onlineEnabled: settings.onlineLyrics), defaults: defaults)
    }

    // Internal composition keeps async regression tests on the real repository without
    // starting a player or acquiring the production session lease.
    init(repository: LyricRepository, defaults: UserDefaults) {
        self.defaults = defaults
        settings = LyricSettings.load(from: defaults)
        playback = PlaybackController()
        self.repository = repository
        lease = TileSessionLease(moduleID: "lyrics")
    }

    /// The kernel lease is the authority. A handoff notification never grants ownership.
    @discardableResult public func start() async -> Bool {
        guard !stopping else { return false }
        if let startBarrier { return await startBarrier.value }
        if ownsSession { return true }
        do {
            guard try lease.acquire() else {
                ownershipMessage = LyricLocalization.text("歌词正在另一个 HOLDSNOW 窗口中显示", "Lyrics are showing in another HOLDSNOW window")
                return false
            }
        } catch {
            ownershipMessage = LyricLocalization.text("暂时无法取得歌词会话：\(error.localizedDescription)", "Unable to start the lyric session: \(error.localizedDescription)")
            return false
        }
        ownsSession = true
        ownershipMessage = nil
        runID = UUID()
        let currentRun = runID
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            defer { startBarrier = nil }
            let stream = await playback.updates()
            guard !stopping, runID == currentRun, !Task.isCancelled else { return false }
            updateTask = Task { [weak self] in
                for await update in stream {
                    guard let self, !Task.isCancelled, self.runID == currentRun, self.ownsSession else { return }
                    self.receive(update)
                }
            }
            await playback.start(preferred: settings.player)
            guard !stopping, runID == currentRun, !Task.isCancelled else { return false }
            restartTimeline()
            return ownsSession
        }
        startBarrier = task
        return await task.value
    }

    /// Callers withdraw their visible surface before awaiting this method.
    public func stop() async {
        if let stopBarrier { await stopBarrier.value; return }
        guard ownsSession || startBarrier != nil else { return }
        stopping = true
        runID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { stopBarrier = nil; stopping = false }
            startBarrier?.cancel()
            if let startBarrier { _ = await startBarrier.value }
            updateTask?.cancel(); updateTask = nil
            cancelLyricRequest()
            cancelCandidateSearch()
            cancelAdjustment()
            importPanel?.cancel(nil); importPanel = nil
            timelineTask?.cancel(); timelineTask = nil
            browseTask?.cancel(); browseTask = nil
            clearArtwork()
            // Already sent transport commands must drain before the new owner may dispatch.
            if let commandTask { await commandTask.value }
            await playback.stop()
            snapshot = .empty; document = nil
            candidates = []; adjustment = nil; advanceMS = 0; seekPreviewMS = nil; seekSelection = nil
            isResolving = false; isSearchingCandidates = false; playbackPositionMS = nil
            controlsVisible = false; panelInteractionActive = false; songMenuIsOpen = false; isVisible = false; browsedCueIndex = nil
            refreshFrame()
            lease.release()
            ownsSession = false
        }
        stopBarrier = task
        await task.value
    }

    public var title: String {
        guard let selection = snapshot.selection else { return LyricLocalization.text("尚未播放音乐", "No music playing") }
        let title = selection.recording.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return title?.isEmpty == false ? title! : LyricLocalization.text("未提供曲名", "Untitled track")
    }
    public var artist: String { snapshot.selection?.recording.artists.joined(separator: LyricLocalization.text("、", ", ")) ?? "" }
    public var durationMS: Int64? { snapshot.selection?.recording.durationMS.flatMap { $0 > 0 ? $0 : nil } }
    public var leadCues: [LyricDomain.Cue] { leadCueCache }
    public var currentCue: LyricDomain.Cue? {
        if let browsedCueIndex, leadCues.indices.contains(browsedCueIndex) { return leadCues[browsedCueIndex] }
        let ids = Set(frame.presentedCues.map(\.cueID))
        return leadCues.first(where: { ids.contains($0.id) }) ?? (document?.timingLevel == .some(.none) ? leadCues.first : nil)
    }
    public var currentCueIndex: Int? { currentCue.flatMap { cue in leadCues.firstIndex(where: { $0.id == cue.id }) } }
    public var previousText: String? { contextText(at: -1) }
    public var nextText: String? { contextText(at: 1) }
    /// Neighbouring authored cues stay distinct from translations and status messages.
    /// During an authored interlude the centre is a gap, with real lines on either side.
    public func contextText(at distance: Int) -> String? {
        guard distance != 0, (-2...2).contains(distance) else { return nil }
        let index: Int
        if let currentCueIndex { index = currentCueIndex + distance }
        else if frame.phase == .interlude, let lookup = frame.lookupMS,
                let next = leadCues.firstIndex(where: { ($0.sourceStartMS ?? Int64.min) > lookup }) {
            index = next + (distance > 0 ? distance - 1 : distance)
        } else { return nil }
        return leadCues.indices.contains(index) ? leadCues[index].text : nil
    }
    public var translationText: String? {
        guard settings.showTranslation, let cue = currentCue else { return nil }
        let translations = document?.lanes.filter { $0.kind == .translation }.flatMap(\.cues) ?? []
        if let linked = translations.first(where: { $0.linkedCueID == cue.id }) { return linked.text }
        guard let start = cue.sourceStartMS, leadCues.filter({ $0.sourceStartMS == start }).count == 1 else { return nil }
        return translations.first { $0.linkedCueID == nil && $0.sourceStartMS == start }?.text
    }
    public var backgroundText: String? {
        guard browsedCueIndex == nil else { return nil }
        let ids = Set(frame.presentedCues.map(\.cueID))
        if let background = document?.lanes.filter({ $0.kind == .background }).flatMap(\.cues)
            .first(where: { ids.contains($0.id) }) { return background.text }
        let focus = currentCue?.id
        return leadCues.first { ids.contains($0.id) && $0.id != focus }?.text
    }
    public var idle: Bool { snapshot.selection == nil && !snapshot.requiresAuthorization && snapshot.statusMessage == nil }
    public var canSeek: Bool {
        ownsSession && !stopping && snapshot.capabilities.canSeek && playbackPositionMS != nil && durationMS != nil && !isPerformingCommand
    }
    public var canAnimateTokens: Bool {
        guard isVisible, browsedCueIndex == nil, frame.phase == .syncedToken,
              snapshot.state == .playing, let anchor = snapshot.anchor,
              anchor.quality == .verifiedSourceAnchor, let error = anchor.expectedErrorMS, error >= 0, error <= 250 else { return false }
        return true
    }
    public var sourceCaption: String {
        if browsedCueIndex != nil { return LyricLocalization.text("正在浏览歌词", "Browsing lyrics") }
        if snapshot.state == .paused { return LyricLocalization.text("已暂停", "Paused") }
        if document?.timingLevel == .some(.none) { return LyricLocalization.text("未同步 · 可手动阅读", "Unsynced · scroll to read") }
        return snapshot.player?.displayName ?? "LyricTile"
    }
    public var sourceAdvanceMS: Int64 {
        document?.sourceTiming.interpretation == .normalizedKnownFormat ? (document?.sourceTiming.sourceAdvanceMS ?? 0) : 0
    }

    public func setControlsVisible(_ visible: Bool) {
        guard controlsVisible != visible else { return }
        controlsVisible = visible
        if !visible { scheduleReturnToCurrent() }
        restartTimeline()
    }
    public func selectPlayer(_ player: PlayerID?) { settings.preferredPlayer = player?.rawValue }
    public func openPlayer() {
        guard let player = snapshot.player ?? settings.player else { return }
        Task { await playback.openPlayer(player) }
    }
    public func reconnect() {
        guard ownsSession else { return }
        Task { await playback.select(snapshot.player ?? settings.player) }
    }
    public func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") { NSWorkspace.shared.open(url) }
    }
    public func perform(_ command: TransportCommand) {
        guard ownsSession, !stopping, !isPerformingCommand, let expected = snapshot.selection else { return }
        isPerformingCommand = true; actionMessage = nil
        commandTask = Task { [weak self, playback] in
            do { try await playback.perform(command, expected: expected) }
            catch { if let self, self.isCurrent(expected) { self.actionMessage = error.localizedDescription } }
            guard let self else { return }
            self.isPerformingCommand = false
            self.seekPreviewMS = nil
            self.commandTask = nil
            self.refreshFrame()
        }
    }
    public func togglePlayback() { perform(snapshot.state == .playing ? .pause : .play) }
    public func beginSeek() {
        guard canSeek else { return }
        seekSelection = snapshot.selection
        seekPreviewMS = playbackPositionMS
    }
    /// Withdrawal must not leave an unfinished drag ready to seek on reappearance.
    public func cancelSeek() {
        seekSelection = nil
        if seekPreviewMS != nil { seekPreviewMS = nil }
    }
    func previewSeek(to value: Double) {
        guard canSeek, let selection = seekSelection, isCurrent(selection), let durationMS,
              value.isFinite, value >= 0, value < Double(Int64.max) else { seekPreviewMS = nil; return }
        seekPreviewMS = min(durationMS, Int64(value))
    }
    public func finishSeek() {
        defer { seekSelection = nil }
        guard canSeek, let selection = seekSelection, isCurrent(selection), let seekPreviewMS else {
            self.seekPreviewMS = nil
            return
        }
        perform(.seek(milliseconds: seekPreviewMS))
    }
    public func seek(to cue: LyricDomain.Cue) {
        guard canSeek, let position = cue.sourceStartMS else { return }
        let target = Double(position) - Double(sourceAdvanceMS) - Double(advanceMS)
        guard target.isFinite, target < Double(Int64.max), target > Double(Int64.min) else { return }
        perform(.seek(milliseconds: max(0, Int64(target))))
    }

    public func show(_ page: LyricAuxiliaryPage) {
        presentation = page
        if page == .candidates { searchCandidates() }
    }
    public func retryLyrics() { if let selection = snapshot.selection { resolve(selection) } }
    public func searchCandidates() {
        guard !stopping, let selection = snapshot.selection else { return }
        cancelCandidateSearch()
        let requestID = candidateRequestID
        isSearchingCandidates = true; actionMessage = nil
        candidateTask = Task { [weak self, repository] in
            do {
                let result = try await repository.searchCandidates(for: selection)
                guard let self, !Task.isCancelled, self.candidateRequestID == requestID, self.isCurrent(selection) else { return }
                self.candidates = result; self.isSearchingCandidates = false
            } catch {
                guard let self, !Task.isCancelled, self.candidateRequestID == requestID, self.isCurrent(selection) else { return }
                self.isSearchingCandidates = false; self.actionMessage = Self.message(for: error)
            }
        }
    }
    public func choose(_ candidate: LyricDomain.Candidate) {
        guard !stopping, let selection = snapshot.selection, Self.sameSession(candidate.request.selection, selection) else { return }
        let requestID = beginLyricRequest(kind: .candidate)
        cancelCandidateSearch()
        lyricTask = Task { [weak self, repository] in
            do {
                let result = try await repository.fetch(candidate)
                guard self?.isCurrent(selection, lyricRequest: requestID) == true else { return }
                try await repository.bind(result, to: selection.recording)
                await self?.accept(result, for: selection, requestID: requestID)
            } catch { self?.finishFailure(error, for: selection, requestID: requestID, reportAction: true) }
        }
    }
    public func changeAdvance(to value: Int64) {
        guard !stopping, !isSavingAdjustment, let selection = snapshot.selection, let document else { return }
        let value = min(10_000, max(-10_000, value))
        adjustmentRequestID = UUID()
        let requestID = adjustmentRequestID
        isSavingAdjustment = true; actionMessage = nil
        adjustmentTask = Task { [weak self, repository] in
            defer {
                if let self, self.adjustmentRequestID == requestID {
                    self.isSavingAdjustment = false
                    self.adjustmentTask = nil
                }
            }
            do {
                try await repository.setAdvance(value, for: selection.recording, document: document)
                guard let self, !Task.isCancelled, self.adjustmentRequestID == requestID,
                      self.isCurrent(selection), self.document?.contentHash == document.contentHash else { return }
                self.advanceMS = value
                self.adjustment = .init(recordingFingerprint: selection.recording.fingerprint, documentContentHash: document.contentHash, userAdvanceMS: value)
                self.refreshFrame(); self.restartTimeline()
            } catch {
                guard let self, !Task.isCancelled, self.adjustmentRequestID == requestID,
                      self.isCurrent(selection), self.document?.contentHash == document.contentHash else { return }
                self.actionMessage = Self.message(for: error)
            }
        }
    }
    public func importLyrics() {
        guard !stopping, let selection = snapshot.selection else { return }
        importPanel?.cancel(nil)
        let panel = NSOpenPanel()
        importPanel = panel
        panel.title = LyricLocalization.text("为当前歌曲导入歌词", "Import lyrics for this track")
        panel.prompt = LyricLocalization.text("导入歌词", "Import lyrics")
        panel.allowedContentTypes = [.plainText, .xml, .data]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        Task { [weak self] in
            let response = await panel.begin()
            guard let self, self.importPanel === panel else { return }
            self.importPanel = nil
            guard response == .OK, let url = panel.url, self.isCurrent(selection) else { return }
            self.importLyrics(from: url, for: selection)
        }
    }

    func importLyrics(from url: URL, for selection: LyricDomain.Selection) {
        guard isCurrent(selection) else { return }
        let requestID = beginLyricRequest(kind: .localImport)
        cancelCandidateSearch(); candidates = []
        lyricTask = Task { [weak self, repository] in
            do {
                let bytes = try await Task.detached(priority: .userInitiated) {
                    let scope = url.startAccessingSecurityScopedResource()
                    defer { if scope { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 2 * 1024 * 1024 else { throw LyricDomain.SourceFailure.invalidDocument(reason: LyricLocalization.text("歌词文件超过 2 MiB", "The lyric file exceeds 2 MiB")) }
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    guard data.count <= 2 * 1024 * 1024 else { throw LyricDomain.SourceFailure.invalidDocument(reason: LyricLocalization.text("歌词文件超过 2 MiB", "The lyric file exceeds 2 MiB")) }
                    return data
                }.value
                guard let self, self.isCurrent(selection, lyricRequest: requestID) else { return }
                let document = try await repository.importLyrics(bytes, format: Self.format(for: url), for: selection)
                await self.accept(document, for: selection, requestID: requestID)
            } catch { self?.finishFailure(error, for: selection, requestID: requestID, reportAction: true) }
        }
    }
    public func clearCache() {
        Task { [weak self, repository] in
            do { try await repository.clearCache(); self?.actionMessage = LyricLocalization.text("自动缓存已清理，已绑定的歌词文件仍保留。", "The automatic cache is cleared. Your saved lyric files are kept.") }
            catch { self?.actionMessage = Self.message(for: error) }
        }
    }
    public func browse(by delta: Int) {
        guard !leadCues.isEmpty else { return }
        browsedCueIndex = min(leadCues.count - 1, max(0, (currentCueIndex ?? 0) + delta))
        scheduleReturnToCurrent()
    }
    public func returnToCurrent() { browseTask?.cancel(); browsedCueIndex = nil; refreshFrame() }

    func receive(_ update: PlaybackSnapshot) {
        let metadataChanged = snapshot.selection != update.selection
        let changed = !Self.sameSession(snapshot.selection, update.selection)
        if changed || update.state != .paused {
            pausedPanelContent = nil
        } else if snapshot.state == .playing, isVisible,
                  panelInteractionActive || songMenuIsOpen || seekPreviewMS != nil {
            pausedPanelContent = panelContent
        }
        snapshot = update
        refreshArtwork(from: update, sessionChanged: changed)
        if changed {
            cancelLyricRequest(); cancelCandidateSearch(); cancelAdjustment(); browseTask?.cancel()
            importPanel?.cancel(nil); importPanel = nil
            document = nil; adjustment = nil; advanceMS = 0; candidates = []; browsedCueIndex = nil
            lyricFailure = nil; actionMessage = nil; seekPreviewMS = nil; seekSelection = nil
            isResolving = false; isSearchingCandidates = false
            if let selection = update.selection { resolve(selection) }
        } else if metadataChanged, let selection = update.selection {
            // Late album/artist/duration fields enrich the same recording; they never erase
            // a correctly bound document. An unresolved query may use the richer metadata.
            cancelCandidateSearch()
            candidates = []
            if document == nil, lyricRequestKind == .automatic || !isResolving { resolve(selection) }
        }
        if (changed || metadataChanged), presentation == .candidates,
           lyricRequestKind == .automatic || !isResolving { searchCandidates() }
        refreshFrame(); restartTimeline()
    }
    private func clearArtwork() {
        artworkTask?.cancel(); artworkTask = nil
        artworkToken = UUID()
        artwork = nil; lastArtworkData = nil
    }
    private func refreshArtwork(from update: PlaybackSnapshot, sessionChanged: Bool) {
        if sessionChanged { clearArtwork() }
        guard let selection = update.selection, let data = update.artwork,
              !data.isEmpty, data.count <= LyricArtworkDecoder.maximumInputBytes else {
            if artworkTask != nil || artwork != nil || lastArtworkData != nil { clearArtwork() }
            return
        }
        guard data != lastArtworkData else { return }
        artworkTask?.cancel()
        artworkToken = UUID()
        let token = artworkToken
        lastArtworkData = data
        artwork = nil
        artworkTask = Task(priority: .utility) { [weak self, artworkDecoder] in
            let thumbnail = await artworkDecoder.thumbnail(from: data)
            guard !Task.isCancelled, let self, self.ownsSession, !self.stopping,
                  self.artworkToken == token, self.isCurrent(selection), self.lastArtworkData == data else { return }
            self.artwork = thumbnail.flatMap(NSImage.init(data:))
            self.artworkTask = nil
        }
    }
    private func rebuildLeadCues() {
        let cues = document?.lanes.filter { $0.kind == .lead }.flatMap(\.cues) ?? []
        leadCueCache = cues.enumerated().sorted { left, right in
            if let a = left.element.sourceStartMS, let b = right.element.sourceStartMS, a != b { return a < b }
            if left.element.sourceStartMS == nil && right.element.sourceStartMS != nil { return false }
            if left.element.sourceStartMS != nil && right.element.sourceStartMS == nil { return true }
            return left.offset < right.offset
        }.map(\.element)
    }
    private func resolve(_ selection: LyricDomain.Selection) {
        guard isCurrent(selection) else { return }
        let requestID = beginLyricRequest()
        let candidateID = candidateRequestID
        lyricTask = Task { [weak self, repository] in
            do {
                let resolution = try await repository.resolve(selection)
                guard let self, self.isCurrent(selection, lyricRequest: requestID) else { return }
                switch resolution {
                case .document(let document): await self.accept(document, for: selection, requestID: requestID)
                case .candidates(let candidates):
                    if self.candidateRequestID == candidateID { self.candidates = candidates }
                    self.isResolving = false; self.refreshFrame()
                case .notFound: self.isResolving = false; self.document = nil; self.refreshFrame()
                }
            } catch { self?.finishFailure(error, for: selection, requestID: requestID) }
        }
    }
    private func accept(_ value: LyricDomain.Document, for selection: LyricDomain.Selection, requestID: UUID) async {
        let timing = await repository.adjustment(for: selection.recording, document: value)
        guard isCurrent(selection, lyricRequest: requestID) else { return }
        if document?.contentHash != value.contentHash { cancelAdjustment() }
        document = value; adjustment = timing; advanceMS = timing?.userAdvanceMS ?? 0
        isResolving = false; lyricFailure = nil; actionMessage = nil; browsedCueIndex = nil
        refreshFrame(); restartTimeline()
    }
    private func finishFailure(_ error: Error, for selection: LyricDomain.Selection, requestID: UUID, reportAction: Bool = false) {
        guard isCurrent(selection, lyricRequest: requestID) else { return }
        isResolving = false; lyricFailure = Self.message(for: error); refreshFrame()
        if reportAction { actionMessage = Self.message(for: error) }
    }
    private func beginLyricRequest(kind: LyricRequestKind = .automatic) -> UUID {
        cancelLyricRequest()
        lyricRequestKind = kind
        isResolving = true; lyricFailure = nil; actionMessage = nil
        refreshFrame()
        return lyricRequestID
    }
    private func cancelLyricRequest() {
        lyricRequestID = UUID()
        lyricTask?.cancel(); lyricTask = nil
    }
    private func cancelCandidateSearch() {
        candidateRequestID = UUID()
        candidateTask?.cancel(); candidateTask = nil
        isSearchingCandidates = false
    }
    private func cancelAdjustment() {
        adjustmentRequestID = UUID()
        adjustmentTask?.cancel(); adjustmentTask = nil
        isSavingAdjustment = false
    }
    private func refreshFrame() {
        guard let selection = snapshot.selection else {
            playbackPositionMS = nil
            frame = .init(selection: nil, phase: .noPlayback, playbackState: snapshot.state, lookupMS: nil, presentedCues: [])
            return
        }
        playbackPositionMS = projectedPosition()
        if let anchor = snapshot.anchor, let projected = try? timeline.frame(anchor: anchor, at: PlaybackClock.now(), document: document, adjustment: adjustment) {
            if isResolving && document == nil {
                frame = .init(selection: selection, phase: .resolving, playbackState: snapshot.state, lookupMS: projected.lookupMS, presentedCues: [])
            } else if document == nil && !isResolving {
                frame = .init(selection: selection, phase: lyricFailure == nil ? .notFound : .sourceUnavailable, playbackState: snapshot.state, lookupMS: projected.lookupMS, presentedCues: [])
            } else { frame = projected }
        } else {
            let phase: LyricDomain.DisplayPhase = isResolving ? .resolving : document?.instrumental == true ? .instrumental : document?.timingLevel == .some(.none) ? .plainText : .positionUnavailable
            frame = .init(selection: selection, phase: phase, playbackState: snapshot.state, lookupMS: nil, presentedCues: [])
        }
    }
    public func projectedPosition() -> Int64? {
        guard let anchor = snapshot.anchor, let position = anchor.positionMS,
              anchor.quality != .unavailable, anchor.quality != .stale else { return nil }
        let now = PlaybackClock.now()
        guard now.clockDomainID == anchor.observedAt.clockDomainID, now.nanoseconds >= anchor.observedAt.nanoseconds else { return nil }
        let elapsed = Double(now.nanoseconds - anchor.observedAt.nanoseconds) / 1_000_000
        guard anchor.state != .unknown, anchor.playbackRate.isFinite,
              anchor.state != .playing || elapsed <= 15_000 else { return nil }
        let value = Double(position) + (anchor.state == .playing ? elapsed * max(0, anchor.playbackRate) : 0)
        guard value.isFinite, value >= 0, value < Double(Int64.max) else { return nil }
        return durationMS.map { min($0, Int64(value)) } ?? Int64(value)
    }
    private func restartTimeline() {
        timelineTask?.cancel(); timelineTask = nil
        guard ownsSession, isVisible, snapshot.state == .playing, snapshot.anchor?.positionMS != nil else { return }
        timelineTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.ownsSession, self.isVisible, self.snapshot.state == .playing else { return }
                let delay = self.nextRefreshDelay()
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard !Task.isCancelled else { return }
                self.refreshFrame()
            }
        }
    }
    private func nextRefreshDelay() -> Double {
        if controlsVisible { return 0.25 }
        guard let lookup = frame.lookupMS else { return 1 }
        let boundary = leadCues.flatMap { [$0.sourceStartMS, $0.sourceEndMS].compactMap { $0 } }.filter { $0 > lookup }.min()
        let delay = boundary.map { (Double($0) - Double(lookup)) / 1000 } ?? 1
        return min(1, max(0.025, delay))
    }
    private func scheduleReturnToCurrent() {
        browseTask?.cancel()
        guard browsedCueIndex != nil, !controlsVisible else { return }
        browseTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.returnToCurrent()
        }
    }
    private func isCurrent(_ selection: LyricDomain.Selection) -> Bool {
        !stopping && Self.sameSession(snapshot.selection, selection)
    }
    private func isCurrent(_ selection: LyricDomain.Selection, lyricRequest requestID: UUID) -> Bool {
        !Task.isCancelled && lyricRequestID == requestID && isCurrent(selection)
    }
    private static func sameSession(_ left: LyricDomain.Selection?, _ right: LyricDomain.Selection?) -> Bool {
        guard let left, let right else { return left == nil && right == nil }
        return left.playerBundleID == right.playerBundleID && left.sessionID == right.sessionID
            && left.generation == right.generation && left.recording.fingerprint == right.recording.fingerprint
    }
    private func settingsChanged(from previous: LyricSettings) {
        settings.save(to: defaults)
        if settings.onlineLyrics != previous.onlineLyrics {
            let enabled = settings.onlineLyrics
            if !enabled {
                if lyricRequestKind != .localImport { cancelLyricRequest(); isResolving = false }
                cancelCandidateSearch(); candidates = []
            }
            Task { [weak self, repository] in
                guard let self, self.settings.onlineLyrics == enabled else { return }
                await repository.setOnlineEnabled(enabled)
                guard self.settings.onlineLyrics == enabled else { return }
                guard self.lyricRequestKind != .localImport || !self.isResolving else { self.refreshFrame(); return }
                if enabled || (self.document == nil && !self.isResolving) { self.retryLyrics() }
                else { self.refreshFrame() }
            }
        }
        if settings.preferredPlayer != previous.preferredPlayer, ownsSession {
            Task { [playback, preferred = settings.player] in await playback.select(preferred) }
        }
    }
    private static func format(for url: URL) -> LyricDomain.Format {
        switch url.pathExtension.lowercased() {
        case "lrc": .lrc
        case "lrcx": .lrcx
        case "ttml", "xml": .ttmlAppleAMLL
        case "qrc": .qrcPlaintext
        case "yrc": .yrcPlaintext
        case "yaml", "yml", "lyricsfile": .lyricsfileV1Draft
        default: .plainText
        }
    }
    private static func message(for error: Error) -> String {
        guard let failure = error as? LyricDomain.SourceFailure else { return error.localizedDescription }
        return switch failure {
        case .notFound: LyricLocalization.text("还没有找到歌词", "No lyrics found")
        case .rateLimited(let seconds): LyricLocalization.text("歌词服务暂时繁忙，请在约 \(max(1, seconds)) 秒后再试。", "The lyric service is busy. Try again in about \(max(1, seconds)) seconds.")
        case .transportUnavailable: LyricLocalization.text("暂时连接不到歌词服务，稍后可以重试。", "Unable to reach the lyric service. Try again later.")
        case .invalidDocument(let reason): LyricLocalization.text("歌词文件无法读取：\(reason)", "Unable to read the lyric file: \(reason)")
        case .unsupportedFormat: LyricLocalization.text("暂不支持这个歌词格式。", "This lyric format is not supported yet.")
        case .unsupportedTimingProfile: LyricLocalization.text("歌词使用了暂不支持的时间格式。", "This lyric timing format is not supported yet.")
        case .staleGeneration: LyricLocalization.text("歌曲已经切换，请为当前歌曲重试。", "The track has changed. Try again for the current track.")
        case .accessUnavailable: LyricLocalization.text("此歌词来源暂不可用，可以导入本地歌词。", "This lyric source is unavailable. You can import a local lyric file.")
        }
    }
}

