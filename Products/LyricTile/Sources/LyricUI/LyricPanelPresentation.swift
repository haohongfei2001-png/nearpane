import AppKit
import CoreText
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

    struct ReadingLayout {
        let contextRadius: Int
        let viewportHeight: CGFloat
        let spacing: CGFloat
    }

    /// Spend the fixed surface on the current cue before distant context.
    /// Measuring the same CoreText frame used by the native view also handles
    /// explicit line breaks, word wrapping and composed/RTL text consistently.
    @MainActor static func readingLayout(for text: String?, fontSize: CGFloat,
                                         availableWidth: CGFloat, hasSupplement: Bool,
                                         controlsVisible: Bool) -> ReadingLayout {
        let row = lineHeight(for: fontSize)
        let requiredRows: Int
        if let text, !text.isEmpty {
            let frame = LyricTextLayout.frame(text: text, fontSize: fontSize, width: availableWidth)
            requiredRows = max(1, CFArrayGetCount(CTFrameGetLines(frame)))
        } else { requiredRows = 1 }
        let longCue = requiredRows > 2
        let spacing: CGFloat = longCue ? 6 : requiredRows > 1 ? 5 : hasSupplement ? 9 : 11
        // Two nearby cues use 40 pt; translations keep their own 16 pt band.
        let availableHeight = lyricsHeight - 24 - 40 - spacing * 2 - (hasSupplement ? 16 : 0)
        let readingRows = longCue ? min(4, Int(availableHeight / row)) : 2
        // Hover keeps complete rows between the existing header and controls.
        // The cue's centre stays fixed; the window never expands on hover.
        let visibleRows = min(requiredRows, controlsVisible ? 2 : readingRows)
        return ReadingLayout(contextRadius: longCue ? 1 : 2,
                             viewportHeight: row * CGFloat(visibleRows), spacing: spacing)
    }
}

@MainActor
extension LyricAppModel {
    public var isRetainingPausedSurface: Bool {
        snapshot.state == .paused && pausedPanelContent != nil
            && (panelInteractionActive || songMenuIsOpen || seekPreviewMS != nil)
    }

    public var panelContent: LyricPanelContent {
        if isRetainingPausedSurface, let pausedPanelContent { return pausedPanelContent }
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
