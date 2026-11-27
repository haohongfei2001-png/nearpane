import Foundation

/// Stateless projection from a real media anchor. The adapter refreshes anchors on seek/wake.
public struct LyricTimeline: LyricTimelineProjecting {
    public let maximumPlayingAnchorAgeMS: Int64
    private let indexCache = TimelineIndexCache()
    public init(maximumPlayingAnchorAgeMS: Int64 = 15_000) {
        self.maximumPlayingAnchorAgeMS = max(1_000, maximumPlayingAnchorAgeMS)
    }

    public func frame(anchor: LyricDomain.PlaybackAnchor, at now: LyricDomain.MonotonicStamp,
                      document: LyricDomain.Document?, adjustment: LyricDomain.UserTimingAdjustment?)
        throws -> LyricDomain.Frame {
        guard now.clockDomainID == anchor.observedAt.clockDomainID else {
            throw LyricTimelineError.differentClockDomains
        }
        guard now.nanoseconds >= anchor.observedAt.nanoseconds else {
            throw LyricTimelineError.timeWentBackwards
        }
        guard let document else { return makeFrame(anchor, .resolving) }
        guard document.recording.fingerprint == anchor.selection.recording.fingerprint else {
            throw LyricTimelineError.differentRecording
        }
        if document.instrumental { return makeFrame(anchor, .instrumental) }
        if document.timingLevel == .none {
            return makeFrame(anchor, .plainText, cues: document.lanes.flatMap(\.cues).map {
                .init(cueID: $0.id, displayHoldUntilMS: nil, activeTokenIDs: [])
            })
        }
        let elapsedMS = (now.nanoseconds - anchor.observedAt.nanoseconds) / 1_000_000
        let healthy = anchor.quality == .verifiedSourceAnchor || anchor.quality == .coarseSourceAnchor
        let fresh = anchor.state != .playing || elapsedMS <= UInt64(maximumPlayingAnchorAgeMS)
        guard let position = anchor.positionMS, position >= 0, healthy, fresh,
              anchor.state != .unknown, anchor.playbackRate.isFinite, anchor.playbackRate >= 0 else {
            return makeFrame(anchor, .positionUnavailable)
        }
        var media = position
        if anchor.state == .playing {
            let advance = Double(elapsedMS) * anchor.playbackRate
            guard advance.isFinite, advance >= 0, advance < Double(Int64.max) else {
                throw LyricTimelineError.invalidPosition
            }
            media = try add(media, Int64(advance.rounded(.down)))
        }
        if let duration = anchor.selection.recording.durationMS, duration >= 0 { media = min(media, duration) }
        let sourceAdvance = document.sourceTiming.interpretation == .normalizedKnownFormat
            ? (document.sourceTiming.sourceAdvanceMS ?? 0) : 0
        let userAdvance: Int64 = {
            guard let adjustment, adjustment.recordingFingerprint == document.recording.fingerprint,
                  adjustment.documentContentHash == document.contentHash else { return 0 }
            return adjustment.userAdvanceMS
        }()
        let lookup = try add(add(media, sourceAdvance), userAdvance)
        let wordEligible = document.timingLevel == .token && anchor.quality == .verifiedSourceAnchor
            && anchor.expectedErrorMS.map { $0 >= 0 && $0 <= 250 } == true
        var presented: [LyricDomain.PresentedCue] = []
        var activeLeadIDs: Set<String> = []
        var leadGap = false

        // Main and background lanes can overlap. A display hold never becomes an authored end.
        let laneIndexes = indexCache.indexes(for: document)
        for lane in laneIndexes where lane.kind == .lead || lane.kind == .background {
            let projected = project(lane: lane, lookup: lookup, wordEligible: wordEligible)
            presented += projected.cues
            if lane.kind == .lead {
                activeLeadIDs.formUnion(projected.cues.map(\.cueID))
                leadGap = leadGap || projected.isKnownGap
            }
        }
        for lane in document.lanes where lane.kind != .lead && lane.kind != .background {
            for cue in lane.cues {
                if let linked = cue.linkedCueID, activeLeadIDs.contains(linked) {
                    presented.append(.init(cueID: cue.id, displayHoldUntilMS: nil, activeTokenIDs: []))
                }
            }
        }
        let phase: LyricDomain.DisplayPhase = leadGap && activeLeadIDs.isEmpty
            ? .interlude : (wordEligible ? .syncedToken : .syncedLine)
        return .init(selection: anchor.selection, phase: phase, playbackState: anchor.state,
                     lookupMS: lookup, presentedCues: presented)
    }

    private func project(lane: TimelineLaneIndex, lookup: Int64, wordEligible: Bool)
        -> (cues: [LyricDomain.PresentedCue], isKnownGap: Bool) {
        let timed = lane.cues
        guard !timed.isEmpty else { return ([], false) }
        var selected: [LyricDomain.PresentedCue] = []
        let upper = upperBound(lane.starts, lookup)
        var index = upper - 1
        while index >= 0 {
            if lane.prefixMaximumEnd[index] <= lookup { break }
            let cue = timed[index]
            let holdUntil = lane.displayEnds[index]
            if holdUntil == nil || lookup < holdUntil! {
                let tokenIDs = wordEligible ? lane.tokenIndexes[index].activeIDs(at: lookup) : []
                selected.append(.init(cueID: cue.id, displayHoldUntilMS: holdUntil, activeTokenIDs: tokenIDs))
            }
            index -= 1
        }
        selected.reverse()
        // An intro before the first known cue is a truthful wait, not proof of an instrumental gap.
        if selected.isEmpty, upper == 0, let first = timed.first,
           let firstStart = first.sourceStartMS, lookup < firstStart {
            selected.append(.init(cueID: first.id, displayHoldUntilMS: firstStart, activeTokenIDs: []))
        }
        return (selected, selected.isEmpty && upper > 0 && upper < timed.count
            && timed[upper - 1].sourceEndMS != nil)
    }

    private func add(_ left: Int64, _ right: Int64) throws -> Int64 {
        let result = left.addingReportingOverflow(right)
        guard !result.overflow else { throw LyricTimelineError.arithmeticOverflow }
        return result.partialValue
    }

    private func makeFrame(_ anchor: LyricDomain.PlaybackAnchor, _ phase: LyricDomain.DisplayPhase,
                           cues: [LyricDomain.PresentedCue] = []) -> LyricDomain.Frame {
        .init(selection: anchor.selection, phase: phase, playbackState: anchor.state,
              lookupMS: nil, presentedCues: cues)
    }
}

private func upperBound(_ starts: [Int64], _ position: Int64) -> Int {
    var low = 0, high = starts.count
    while low < high {
        let middle = low + (high - low) / 2
        if starts[middle] <= position { low = middle + 1 } else { high = middle }
    }
    return low
}

private func inferredDisplayEnds(starts: [Int64], realEnds: [Int64?]) -> [Int64?] {
    var ends = realEnds
    var nextDistinct: Int64?
    if starts.isEmpty { return ends }
    for index in starts.indices.reversed() {
        if index + 1 < starts.count, starts[index + 1] > starts[index] { nextDistinct = starts[index + 1] }
        if ends[index] == nil { ends[index] = nextDistinct }
    }
    return ends
}

private func prefixEnds(_ ends: [Int64?]) -> [Int64] {
    var maximum: Int64 = 0
    return ends.map { end in
        maximum = max(maximum, end ?? Int64.max)
        return maximum
    }
}

private struct TimelineTokenIndex: Sendable {
    let tokens: [LyricDomain.Token]
    let starts: [Int64]
    let displayEnds: [Int64?]
    let prefixMaximumEnd: [Int64]
    init(tokens: [LyricDomain.Token]) {
        let sorted = tokens.sorted { $0.sourceStartMS < $1.sourceStartMS }
        self.tokens = sorted
        starts = sorted.map(\.sourceStartMS)
        displayEnds = inferredDisplayEnds(starts: starts, realEnds: sorted.map(\.sourceEndMS))
        prefixMaximumEnd = prefixEnds(displayEnds)
    }
    func activeIDs(at lookup: Int64) -> Set<String> {
        var active: Set<String> = []
        var index = upperBound(starts, lookup) - 1
        while index >= 0 {
            if prefixMaximumEnd[index] <= lookup { break }
            if displayEnds[index] == nil || lookup < displayEnds[index]! { active.insert(tokens[index].id) }
            index -= 1
        }
        return active
    }
}

private struct TimelineLaneIndex: Sendable {
    let kind: LyricDomain.LaneKind
    let cues: [LyricDomain.Cue]
    let starts: [Int64]
    let displayEnds: [Int64?]
    let prefixMaximumEnd: [Int64]
    let tokenIndexes: [TimelineTokenIndex]
    init(lane: LyricDomain.Lane) {
        kind = lane.kind
        cues = lane.cues.filter { $0.sourceStartMS != nil }.sorted { $0.sourceStartMS! < $1.sourceStartMS! }
        starts = cues.compactMap(\.sourceStartMS)
        displayEnds = inferredDisplayEnds(starts: starts, realEnds: cues.map(\.sourceEndMS))
        prefixMaximumEnd = prefixEnds(displayEnds)
        tokenIndexes = cues.map { TimelineTokenIndex(tokens: $0.tokens) }
    }
}

/// The only mutable timeline storage. All access is protected by lock; compiled indexes are values.
/// At most two documents are retained, avoiding re-sorting or traversing all cues at display rate.
private final class TimelineIndexCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(id: UUID, hash: String, schema: UInt32, indexes: [TimelineLaneIndex])] = []
    func indexes(for document: LyricDomain.Document) -> [TimelineLaneIndex] {
        lock.lock(); defer { lock.unlock() }
        if let entry = entries.first(where: { $0.id == document.id && $0.hash == document.contentHash && $0.schema == document.schemaVersion }) {
            return entry.indexes
        }
        let indexes = document.lanes.map { TimelineLaneIndex(lane: $0) }
        entries.append((document.id, document.contentHash, document.schemaVersion, indexes))
        if entries.count > 2 { entries.removeFirst() }
        return indexes
    }
}
