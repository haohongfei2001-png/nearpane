import AppKit
import LyricCore
import LyricPlayback

public enum LyricPanelContent: Equatable, Sendable {
    case lyrics, compact
}

public enum LyricPanelLayout {
    public static let lyricsHeight: CGFloat = 192
    public static let compactHeight: CGFloat = 104
    public static let maximumHeight: CGFloat = lyricsHeight

    static func lineHeight(for fontSize: CGFloat) -> CGFloat {
        fontSize >= 22 ? 29 : fontSize <= 18 ? 25 : 27
    }

    /// A single short cue does not reserve an unused second row. The outer
    /// tile is stable; the native glyph viewport uses one or two whole rows.
    @MainActor static func lyricViewportHeight(for text: String?, fontSize: CGFloat,
                                               availableWidth: CGFloat) -> CGFloat {
        let row = lineHeight(for: fontSize)
        guard let text, !text.isEmpty else { return row }
        let singleWidth = (text as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium)
        ]).width
        let fits = text.rangeOfCharacter(from: .newlines) == nil
            && singleWidth <= max(0, availableWidth - 8)
        return row * (fits ? 1 : 2)
    }
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
