import Foundation

public struct LyricMatcher: LyricMatching {
    public init() {}

    public func evidence(for candidate: LyricDomain.RecordingIdentity,
                         against recording: LyricDomain.RecordingIdentity) -> LyricDomain.MatchEvidence {
        let leftTitle = candidate.title.map(RecordingText.normalize).flatMap { $0.isEmpty ? nil : $0 }
        let rightTitle = recording.title.map(RecordingText.normalize).flatMap { $0.isEmpty ? nil : $0 }
        let candidateArtists = Set(candidate.artists.map(RecordingText.normalize).filter { !$0.isEmpty })
        let targetArtists = Set(recording.artists.map(RecordingText.normalize).filter { !$0.isEmpty })
        let artistKnown = !candidateArtists.isEmpty && !targetArtists.isEmpty
        let artistMatch = artistKnown ? !candidateArtists.isDisjoint(with: targetArtists) : nil
        let primaryConflict = artistKnown && candidate.artists.first.map(RecordingText.normalize)
            != recording.artists.first.map(RecordingText.normalize) && artistMatch == false
        let titleSimilarity = leftTitle.flatMap { left in rightTitle.map { similarity(left, $0) } }
        let albumMatch: Bool? = {
            guard let left = candidate.album, let right = recording.album,
                  !left.isEmpty, !right.isEmpty else { return nil }
            return RecordingText.normalize(left) == RecordingText.normalize(right)
        }()
        let exactID = candidate.platformIDs.contains { left in
            recording.platformIDs.contains { right in
                left.namespace == right.namespace && left.value == right.value && !left.value.isEmpty
                    && (left.storefront == nil || right.storefront == nil || left.storefront == right.storefront)
            }
        }
        let candidateVersions = versionMarkers(candidate)
        let recordingVersions = versionMarkers(recording)
        let versionConflict = candidateVersions != recordingVersions
        let delta: Int64? = {
            guard let left = candidate.durationMS, let right = recording.durationMS,
                  left >= 0, right >= 0 else { return nil }
            return left >= right ? left - right : right - left
        }()
        var reasons: [String] = []
        if exactID { reasons.append("exact_namespaced_id") }
        if candidate.isrc?.uppercased() == recording.isrc?.uppercased(),
           let isrc = candidate.isrc, !isrc.isEmpty { reasons.append("same_isrc") }
        if versionConflict { reasons.append("version_markers_differ") }
        if primaryConflict { reasons.append("main_artist_conflict") }
        if delta == nil { reasons.append("duration_unknown") }
        return .init(exactProviderIdentity: exactID, titleSimilarity: titleSimilarity,
                     mainArtistMatch: artistMatch, albumMatch: albumMatch,
                     mainArtistConflict: primaryConflict, versionConflict: versionConflict,
                     durationDeltaMS: delta, reasons: reasons)
    }

    public func mayAutomaticallyAccept(_ evidence: LyricDomain.MatchEvidence) -> Bool {
        guard !evidence.versionConflict, !evidence.mainArtistConflict else { return false }
        // IDs support identity, but do not override an incompatible recording duration or title.
        if let delta = evidence.durationDeltaMS, delta > 5_000 { return false }
        if evidence.exactProviderIdentity {
            return evidence.titleSimilarity.map { $0 >= 0.9 } ?? true
        }
        guard evidence.titleSimilarity == 1, evidence.mainArtistMatch == true,
              let delta = evidence.durationDeltaMS else { return false }
        if delta <= 2_000 { return true }
        return delta <= 5_000 && evidence.albumMatch == true && evidence.reasons.contains("same_isrc")
    }

    private func versionMarkers(_ recording: LyricDomain.RecordingIdentity) -> Set<String> {
        let source = RecordingText.normalize(([recording.title ?? ""] + recording.versionTags).joined(separator: " "))
        let padded = " " + source + " "
        let groups: [(String, [String])] = [
            ("live", [" live ", "现场", "現場", "演唱会", "演唱會", "ライブ"]),
            ("remix", [" remix ", "混音"]), ("acoustic", [" acoustic ", " unplugged ", "不插电", "不插電"]),
            ("instrumental", [" instrumental ", " karaoke ", "伴奏", "纯音乐", "純音樂"]),
            ("clean", [" clean ", " radio edit "]), ("explicit", [" explicit "]),
            ("sped_up", [" sped up ", " speed up ", " nightcore ", "加速"]),
            ("slowed", [" slowed ", " slow version ", "减速", "慢速"]),
            ("rerecorded", [" re recorded ", " rerecorded ", " taylor s version ", "重录", "重錄"]),
            ("remaster", [" remaster ", " remastered ", "重制", "重製"])
        ]
        var result = Set(groups.filter { _, terms in terms.contains(where: padded.contains) }.map(\.0))
        // An explicit version field is evidence, even if the vocabulary above does not know it.
        for tag in recording.versionTags {
            let normalized = RecordingText.normalize(tag)
            if !normalized.isEmpty { result.insert(normalized) }
        }
        return result
    }

    private func similarity(_ left: String, _ right: String) -> Double {
        if left == right { return 1 }
        let a = Set(left.split(separator: " "))
        let b = Set(right.split(separator: " "))
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }
}
