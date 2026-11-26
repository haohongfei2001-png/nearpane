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
    @Published public private(set) var document: LyricDomain.Document?
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
    private let lease: TileSessionLease
    private let defaults: UserDefaults
    private var adjustment: LyricDomain.UserTimingAdjustment?
    private var updateTask: Task<Void, Never>?
    private var lyricTask: Task<Void, Never>?
    private var candidateTask: Task<Void, Never>?
    private var timelineTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var browseTask: Task<Void, Never>?
    private var startBarrier: Task<Bool, Never>?
    private var stopBarrier: Task<Void, Never>?
    private var runID = UUID()
    private var stopping = false
    private var lastArtworkData: Data?

    public init(storageURL: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let settings = LyricSettings.load(from: defaults)
        self.settings = settings
        let directory = storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HOLDSNOW/LyricTile", isDirectory: true)
        playback = PlaybackController()
        repository = LyricRepository(storageURL: directory, onlineEnabled: settings.onlineLyrics)
        lease = TileSessionLease(moduleID: "lyrics")
    }

    /// The kernel lease is the authority. A handoff notification never grants ownership.
    @discardableResult public func start() async -> Bool {
        guard !stopping else { return false }
        if let startBarrier { return await startBarrier.value }
        if ownsSession { return true }
        do {
            guard try lease.acquire() else {
                ownershipMessage = "歌词正在另一个 HOLDSNOW 窗口中显示"
                return false
            }
        } catch {
            ownershipMessage = "暂时无法取得歌词会话：\(error.localizedDescription)"
            return false
        }
        ownsSession = true
        ownershipMessage = nil
        runID = UUID()
        let currentRun = runID
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
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
        let result = await task.value
        startBarrier = nil
        return result
    }

    /// Callers withdraw their visible surface before awaiting this method.
    public func stop() async {
        if let stopBarrier { await stopBarrier.value; return }
        guard ownsSession || startBarrier != nil else { return }
        stopping = true
        runID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            startBarrier?.cancel()
            if let startBarrier { _ = await startBarrier.value }
            updateTask?.cancel(); updateTask = nil
            lyricTask?.cancel(); lyricTask = nil
            candidateTask?.cancel(); candidateTask = nil
            timelineTask?.cancel(); timelineTask = nil
            browseTask?.cancel(); browseTask = nil
            // Already sent transport commands must drain before the new owner may dispatch.
            if let commandTask { await commandTask.value }
            await playback.stop()
            snapshot = .empty; document = nil; artwork = nil; lastArtworkData = nil
            candidates = []; adjustment = nil; advanceMS = 0; seekPreviewMS = nil
            isResolving = false; isSearchingCandidates = false; playbackPositionMS = nil
            controlsVisible = false; songMenuIsOpen = false; isVisible = false; browsedCueIndex = nil
            refreshFrame()
            lease.release()
            ownsSession = false
            stopping = false
        }
        stopBarrier = task
        await task.value
        stopBarrier = nil
    }

    public var title: String { snapshot.selection?.recording.title ?? "尚未播放音乐" }
    public var artist: String { snapshot.selection?.recording.artists.joined(separator: "、") ?? "" }
    public var durationMS: Int64? { snapshot.selection?.recording.durationMS.flatMap { $0 > 0 ? $0 : nil } }
    public var leadCues: [LyricDomain.Cue] { document?.lanes.first(where: { $0.kind == .lead })?.cues ?? [] }
    public var currentCue: LyricDomain.Cue? {
        if let browsedCueIndex, leadCues.indices.contains(browsedCueIndex) { return leadCues[browsedCueIndex] }
        let ids = Set(frame.presentedCues.map(\.cueID))
        return leadCues.first(where: { ids.contains($0.id) }) ?? (document?.timingLevel == .none ? leadCues.first : nil)
    }
    public var currentCueIndex: Int? { currentCue.flatMap { cue in leadCues.firstIndex(where: { $0.id == cue.id }) } }
    public var previousText: String? { currentCueIndex.flatMap { $0 > 0 ? leadCues[$0 - 1].text : nil } }
    public var nextText: String? { currentCueIndex.flatMap { $0 + 1 < leadCues.count ? leadCues[$0 + 1].text : nil } }
    public var translationText: String? {
        guard settings.showTranslation, let cue = currentCue else { return nil }
        return document?.lanes.filter { $0.kind == .translation }.flatMap(\.cues)
            .first { $0.linkedCueID == cue.id || ($0.sourceStartMS != nil && $0.sourceStartMS == cue.sourceStartMS) }?.text
    }
    public var backgroundText: String? {
        guard browsedCueIndex == nil else { return nil }
        let ids = Set(frame.presentedCues.map(\.cueID))
        return document?.lanes.filter { $0.kind == .background }.flatMap(\.cues)
            .first { ids.contains($0.id) }?.text
    }
    public var idle: Bool { snapshot.selection == nil && !snapshot.requiresAuthorization }
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
        if browsedCueIndex != nil { return "正在浏览歌词" }
        if snapshot.state == .paused { return "已暂停" }
        if document?.timingLevel == .none { return "未同步 · 可手动阅读" }
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
            catch { if let self, self.snapshot.selection == expected { self.actionMessage = error.localizedDescription } }
            guard let self else { return }
            self.isPerformingCommand = false
            self.seekPreviewMS = nil
            self.commandTask = nil
            self.refreshFrame()
        }
    }
    public func togglePlayback() { perform(snapshot.state == .playing ? .pause : .play) }
    public func beginSeek() { if canSeek { seekPreviewMS = playbackPositionMS } }
    public func finishSeek() {
        guard canSeek, let seekPreviewMS else { self.seekPreviewMS = nil; return }
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
        guard let selection = snapshot.selection else { return }
        candidateTask?.cancel(); isSearchingCandidates = true
        candidateTask = Task { [weak self, repository] in
            do {
                let result = try await repository.searchCandidates(for: selection)
                guard let self, !Task.isCancelled, self.snapshot.selection == selection else { return }
                self.candidates = result; self.isSearchingCandidates = false
            } catch {
                guard let self, !Task.isCancelled, self.snapshot.selection == selection else { return }
                self.isSearchingCandidates = false; self.actionMessage = Self.message(for: error)
            }
        }
    }
    public func choose(_ candidate: LyricDomain.Candidate) {
        guard let selection = snapshot.selection, candidate.request.selection == selection else { return }
        lyricTask?.cancel(); isResolving = true
        lyricTask = Task { [weak self, repository] in
            do {
                let result = try await repository.fetch(candidate)
                guard !Task.isCancelled, self?.snapshot.selection == selection else { return }
                try await repository.bind(result, to: selection.recording)
                await self?.accept(result, for: selection)
            } catch { self?.finishFailure(error, for: selection) }
        }
    }
    public func changeAdvance(to value: Int64) {
        guard !isSavingAdjustment, let selection = snapshot.selection, let document else { return }
        let value = min(10_000, max(-10_000, value))
        isSavingAdjustment = true
        Task { [weak self, repository] in
            do {
                try await repository.setAdvance(value, for: selection.recording, document: document)
                guard let self, self.snapshot.selection == selection, self.document?.contentHash == document.contentHash else {
                    self?.isSavingAdjustment = false
                    return
                }
                self.advanceMS = value
                self.adjustment = .init(recordingFingerprint: selection.recording.fingerprint, documentContentHash: document.contentHash, userAdvanceMS: value)
                self.refreshFrame(); self.restartTimeline()
            } catch { self?.actionMessage = Self.message(for: error) }
            self?.isSavingAdjustment = false
        }
    }
    public func importLyrics() {
        guard let selection = snapshot.selection else { return }
        Task { [weak self, repository] in
            let panel = NSOpenPanel()
            panel.title = "为当前歌曲导入歌词"
            panel.prompt = "导入歌词"
            panel.allowedContentTypes = [.plainText, .xml, .data]
            panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
            guard await panel.begin() == .OK, let url = panel.url, let self, self.snapshot.selection == selection else { return }
            do {
                let bytes = try await Task.detached(priority: .userInitiated) {
                    let scope = url.startAccessingSecurityScopedResource()
                    defer { if scope { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 2 * 1024 * 1024 else { throw LyricDomain.SourceFailure.invalidDocument(reason: "歌词文件超过 2 MiB") }
                    return try Data(contentsOf: url, options: .mappedIfSafe)
                }.value
                guard self.snapshot.selection == selection else { return }
                let document = try await repository.importLyrics(bytes, format: Self.format(for: url), for: selection)
                await self.accept(document, for: selection)
            } catch { self.actionMessage = Self.message(for: error) }
        }
    }
    public func clearCache() {
        Task { [weak self, repository] in
            do { try await repository.clearCache(); self?.actionMessage = "自动缓存已清理，已绑定的歌词文件仍保留。" }
            catch { self?.actionMessage = Self.message(for: error) }
        }
    }
    public func browse(by delta: Int) {
        guard !leadCues.isEmpty else { return }
        browsedCueIndex = min(leadCues.count - 1, max(0, (currentCueIndex ?? 0) + delta))
        scheduleReturnToCurrent()
    }
    public func returnToCurrent() { browseTask?.cancel(); browsedCueIndex = nil; refreshFrame() }

    private func receive(_ update: PlaybackSnapshot) {
        let changed = snapshot.selection != update.selection
        snapshot = update
        if update.artwork != lastArtworkData {
            lastArtworkData = update.artwork
            artwork = update.artwork.flatMap(NSImage.init(data:))
        }
        if changed {
            lyricTask?.cancel(); candidateTask?.cancel(); browseTask?.cancel()
            document = nil; adjustment = nil; advanceMS = 0; candidates = []; browsedCueIndex = nil
            lyricFailure = nil; actionMessage = nil; seekPreviewMS = nil; isResolving = false
            if let selection = update.selection { resolve(selection) }
        }
        refreshFrame(); restartTimeline()
    }
    private func resolve(_ selection: LyricDomain.Selection) {
        lyricTask?.cancel(); isResolving = true; lyricFailure = nil
        lyricTask = Task { [weak self, repository] in
            do {
                let resolution = try await repository.resolve(selection)
                guard let self, !Task.isCancelled, self.snapshot.selection == selection else { return }
                switch resolution {
                case .document(let document): await self.accept(document, for: selection)
                case .candidates(let candidates): self.candidates = candidates; self.isResolving = false; self.refreshFrame()
                case .notFound: self.isResolving = false; self.document = nil; self.refreshFrame()
                }
            } catch { self?.finishFailure(error, for: selection) }
        }
    }
    private func accept(_ value: LyricDomain.Document, for selection: LyricDomain.Selection) async {
        let timing = await repository.adjustment(for: selection.recording, document: value)
        guard !Task.isCancelled, snapshot.selection == selection else { return }
        document = value; adjustment = timing; advanceMS = timing?.userAdvanceMS ?? 0
        isResolving = false; lyricFailure = nil; browsedCueIndex = nil
        refreshFrame(); restartTimeline()
    }
    private func finishFailure(_ error: Error, for selection: LyricDomain.Selection) {
        guard !Task.isCancelled, snapshot.selection == selection else { return }
        isResolving = false; lyricFailure = Self.message(for: error); refreshFrame()
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
            let phase: LyricDomain.DisplayPhase = isResolving ? .resolving : document?.instrumental == true ? .instrumental : document?.timingLevel == .none ? .plainText : .positionUnavailable
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
        return min(1, max(0.025, Double((boundary ?? (lookup + 1000)) - lookup) / 1000))
    }
    private func scheduleReturnToCurrent() {
        browseTask?.cancel()
        guard browsedCueIndex != nil, !controlsVisible else { return }
        browseTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.returnToCurrent()
        }
    }
    private func settingsChanged(from previous: LyricSettings) {
        settings.save(to: defaults)
        if settings.onlineLyrics != previous.onlineLyrics {
            let enabled = settings.onlineLyrics
            if !enabled {
                lyricTask?.cancel(); candidateTask?.cancel()
                isResolving = false; isSearchingCandidates = false
            }
            Task { [weak self, repository] in
                await repository.setOnlineEnabled(enabled)
                if enabled { self?.retryLyrics() } else { self?.refreshFrame() }
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
        case .notFound: "还没有找到歌词"
        case .rateLimited(let seconds): "歌词服务暂时繁忙，请在约 \(max(1, seconds)) 秒后再试。"
        case .transportUnavailable: "暂时连接不到歌词服务，稍后可以重试。"
        case .invalidDocument(let reason): "歌词文件无法读取：\(reason)"
        case .unsupportedFormat: "暂不支持这个歌词格式。"
        case .unsupportedTimingProfile: "歌词使用了暂不支持的时间格式。"
        case .staleGeneration: "歌曲已经切换，请为当前歌曲重试。"
        case .accessUnavailable: "此歌词来源暂不可用，可以导入本地歌词。"
        }
    }
}
