import LyricCore

/// Preserve identifying metadata only inside the same verified native process and
/// media session. No clock, source ownership or capability is manufactured here.
/// Transport still performs a fresh read and confirms every command separately.
enum PlaybackObservationContinuity {
    static func merging(_ incoming: PlayerObservation, with previous: PlayerObservation?) -> PlayerObservation {
        guard let previous, previous.hasRecording,
              incoming.process == previous.process,
              incoming.mediaPID == previous.mediaPID,
              incoming.mediaProcessStart == previous.mediaProcessStart,
              !incoming.hasRecording || PlaybackSelectionTracker.sameRecording(previous, incoming) else { return incoming }
        var result = incoming
        if result.title?.isEmpty != false { result.title = previous.title }
        if result.artist?.isEmpty != false { result.artist = previous.artist }
        if result.album?.isEmpty != false { result.album = previous.album }
        if result.platformID?.isEmpty != false { result.platformID = previous.platformID }
        if result.durationMS == nil { result.durationMS = previous.durationMS }
        if result.artwork == nil { result.artwork = previous.artwork }
        if result.artworkURL == nil { result.artworkURL = previous.artworkURL }
        return result
    }
}
