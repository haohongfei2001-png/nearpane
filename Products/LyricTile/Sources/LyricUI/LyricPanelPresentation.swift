import CoreGraphics
import LyricCore
import LyricPlayback

public enum LyricPanelContent: Equatable, Sendable {
    case lyrics, compact
}

public enum LyricPanelLayout {
    public static let lyricsHeight: CGFloat = 204
    public static let compactHeight: CGFloat = 112
    public static let maximumHeight: CGFloat = 204
}

@MainActor
extension LyricAppModel {
    public var panelContent: LyricPanelContent {
        if frame.phase == .interlude { return .lyrics }
        if currentCue != nil,
           browsedCueIndex != nil || [.syncedLine, .syncedToken, .plainText].contains(frame.phase) {
            return .lyrics
        }
        return .compact
    }
}

/// A paused player may retain controls already under the user's pointer. It never
/// creates a panel for a paused song at launch, even when VoiceOver reveals controls.
struct LyricPanelVisibilityPolicy {
    private var retainsPausedInteraction = false
    private var previousSelection: LyricDomain.Selection?

    mutating func shouldPresent(_ snapshot: PlaybackSnapshot, wasVisible: Bool,
                                isInteracting: Bool) -> Bool {
        let sameSelection = previousSelection.map { previous in
            guard let selection = snapshot.selection else { return false }
            return previous.playerBundleID == selection.playerBundleID
                && previous.sessionID == selection.sessionID
                && previous.generation == selection.generation
                && previous.recording.fingerprint == selection.recording.fingerprint
        } ?? false
        defer { previousSelection = snapshot.selection }
        guard snapshot.selection != nil else {
            retainsPausedInteraction = false
            return false
        }
        switch snapshot.state {
        case .playing:
            retainsPausedInteraction = false
            return true
        case .paused:
            retainsPausedInteraction = sameSelection && isInteracting && (wasVisible || retainsPausedInteraction)
            return retainsPausedInteraction
        case .stopped, .buffering, .unknown:
            retainsPausedInteraction = false
            return false
        }
    }
}
