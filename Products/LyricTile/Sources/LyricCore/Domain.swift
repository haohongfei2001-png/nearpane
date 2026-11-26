// HOLDSNOW · LyricTile · Swift 6 interface blueprint · 2026-11-26
// This file defines contracts only. No player, provider, renderer, or test data is implemented.
// Not typechecked in this research environment: a Swift compiler was unavailable.
import Foundation

public enum LyricDomain {
    // Media positions are nonnegative Int64 milliseconds. Offsets are signed Int64 milliseconds.
    // Validate at parsing / adapter boundaries; unknown values remain nil, never zero.
    public struct PlatformTrackID: Hashable, Codable, Sendable {
        public let namespace: String
        public let value: String
        public let storefront: String?
        public init(namespace: String, value: String, storefront: String? = nil) {
            self.namespace = namespace; self.value = value; self.storefront = storefront
        }
    }

    public struct RecordingIdentity: Hashable, Codable, Sendable {
        public let fingerprint: String
        public let platformIDs: [PlatformTrackID]
        public let isrc: String?
        public let title: String?
        public let artists: [String]
        public let album: String?
        public let durationMS: Int64?
        public let versionTags: [String]
        public init(fingerprint: String, platformIDs: [PlatformTrackID], isrc: String?,
                    title: String?, artists: [String], album: String?, durationMS: Int64?,
                    versionTags: [String]) {
            self.fingerprint = fingerprint; self.platformIDs = platformIDs; self.isrc = isrc
            self.title = title; self.artists = artists; self.album = album
            self.durationMS = durationMS; self.versionTags = versionTags
        }
    }

    // A player/session switch or changed recording issues a new generation. Seek does not.
    public struct Selection: Hashable, Codable, Sendable {
        public let playerBundleID: String
        public let sessionID: UUID
        public let generation: UInt64
        public let recording: RecordingIdentity
        public init(playerBundleID: String, sessionID: UUID, generation: UInt64,
                    recording: RecordingIdentity) {
            self.playerBundleID = playerBundleID; self.sessionID = sessionID
            self.generation = generation; self.recording = recording
        }
    }

    // Ephemeral. Compare only stamps with the same clockDomainID; never persist for resume.
    public struct MonotonicStamp: Hashable, Sendable {
        public let nanoseconds: UInt64
        public let clockDomainID: UUID
        public init(nanoseconds: UInt64, clockDomainID: UUID) {
            self.nanoseconds = nanoseconds; self.clockDomainID = clockDomainID
        }
    }
    public enum PlaybackState: String, Hashable, Codable, Sendable {
        case playing, paused, stopped, buffering, unknown
    }
    public enum ClockQuality: String, Hashable, Codable, Sendable {
        case verifiedSourceAnchor, coarseSourceAnchor, stale, unavailable
    }
    public struct PlaybackAnchor: Hashable, Sendable {
        public let selection: Selection
        public let positionMS: Int64?
        public let observedAt: MonotonicStamp
        public let playbackRate: Double
        public let state: PlaybackState
        public let quality: ClockQuality
        public let expectedErrorMS: Int64?
        public init(selection: Selection, positionMS: Int64?, observedAt: MonotonicStamp,
                    playbackRate: Double, state: PlaybackState, quality: ClockQuality,
                    expectedErrorMS: Int64?) {
            self.selection = selection; self.positionMS = positionMS; self.observedAt = observedAt
            self.playbackRate = playbackRate; self.state = state; self.quality = quality
            self.expectedErrorMS = expectedErrorMS
        }
    }

    // API access and lyric-content rights are independent evidence dimensions.
    public enum APIAccessBasis: String, Hashable, Codable, Sendable {
        case localFile, publishedTerms, registeredClient, signedAgreement, unresolved
    }
    public enum ContentRightsBasis: String, Hashable, Codable, Sendable {
        case userProvidedUnverified, documentedPermission, providerTerms, unresolved
    }
    public struct RightsEvidence: Hashable, Codable, Sendable {
        public let apiAccess: APIAccessBasis
        public let apiEvidenceURL: URL?
        public let contentRights: ContentRightsBasis
        public let contentEvidenceURL: URL?
        public let reviewedAt: Date
        public let evidenceRevision: String?
        public let territories: [String]
        public let expiry: Date?
        public let cacheMaxAgeSeconds: Int64?
        public let attributionText: String?
        public init(apiAccess: APIAccessBasis, apiEvidenceURL: URL?,
                    contentRights: ContentRightsBasis, contentEvidenceURL: URL?,
                    reviewedAt: Date, evidenceRevision: String?,
                    territories: [String], expiry: Date?, cacheMaxAgeSeconds: Int64?,
                    attributionText: String?) {
            self.apiAccess = apiAccess; self.apiEvidenceURL = apiEvidenceURL
            self.contentRights = contentRights; self.contentEvidenceURL = contentEvidenceURL
            self.reviewedAt = reviewedAt; self.evidenceRevision = evidenceRevision
            self.territories = territories; self.expiry = expiry
            self.cacheMaxAgeSeconds = cacheMaxAgeSeconds; self.attributionText = attributionText
        }
    }
    public enum ProviderReleaseDisposition: String, Hashable, Codable, Sendable {
        case internalResearch, approvedPublicOptional, approvedPublicDefault, disabled
    }
    public struct ProviderDescriptor: Hashable, Codable, Sendable {
        public let providerID: String
        public let displayName: String
        public let codeLicenseSPDX: String?
        public let rights: RightsEvidence
        public let releaseDisposition: ProviderReleaseDisposition
        public init(providerID: String, displayName: String, codeLicenseSPDX: String?,
                    rights: RightsEvidence, releaseDisposition: ProviderReleaseDisposition) {
            self.providerID = providerID; self.displayName = displayName
            self.codeLicenseSPDX = codeLicenseSPDX; self.rights = rights
            self.releaseDisposition = releaseDisposition
        }
    }
    public struct SourceProvenance: Hashable, Codable, Sendable {
        public let providerID: String
        public let providerRecordID: String?
        public let sourceURL: URL?
        public let fetchedAt: Date
        public let revisionOrETag: String?
        public let contributorCredit: String?
        public let rights: RightsEvidence
        public init(providerID: String, providerRecordID: String?, sourceURL: URL?,
                    fetchedAt: Date, revisionOrETag: String?, contributorCredit: String?,
                    rights: RightsEvidence) {
            self.providerID = providerID; self.providerRecordID = providerRecordID
            self.sourceURL = sourceURL; self.fetchedAt = fetchedAt
            self.revisionOrETag = revisionOrETag; self.contributorCredit = contributorCredit
            self.rights = rights
        }
    }

    public enum Format: String, Hashable, Codable, Sendable {
        case lrc, lrcx, enhancedLRC, ttmlAppleAMLL, qrcPlaintext, yrcPlaintext
        case lyricsfileV1Draft, plainText
    }
    public enum TimingLevel: String, Hashable, Codable, Sendable { case none, line, token }
    public enum LaneKind: String, Hashable, Codable, Sendable {
        case lead, background, translation, romanization, ruby
    }
    public enum OffsetInterpretation: String, Hashable, Codable, Sendable {
        case absent, normalizedKnownFormat, unresolved
    }
    public struct SourceTiming: Hashable, Codable, Sendable {
        // Positive advance means look farther ahead in the lyric document.
        // An unresolved Lyricsfile offset stays nil and is NOT interpreted as LRC offset.
        public let sourceAdvanceMS: Int64?
        public let interpretation: OffsetInterpretation
        public let rawOffset: String?
        public init(sourceAdvanceMS: Int64?, interpretation: OffsetInterpretation, rawOffset: String?) {
            self.sourceAdvanceMS = sourceAdvanceMS; self.interpretation = interpretation
            self.rawOffset = rawOffset
        }
    }
    public struct UserTimingAdjustment: Hashable, Codable, Sendable {
        public let recordingFingerprint: String
        public let documentContentHash: String
        public let userAdvanceMS: Int64
        public init(recordingFingerprint: String, documentContentHash: String, userAdvanceMS: Int64) {
            self.recordingFingerprint = recordingFingerprint
            self.documentContentHash = documentContentHash; self.userAdvanceMS = userAdvanceMS
        }
    }
    public struct UTF16Span: Hashable, Codable, Sendable {
        // Range refers to the exact cue.text. Renderer checks bounds and grapheme boundaries
        // before converting to NSRange / Core Text glyph runs; String.count is not UTF16 count.
        public let location: Int
        public let length: Int
        public init(location: Int, length: Int) { self.location = location; self.length = length }
    }
    public struct Token: Hashable, Codable, Sendable {
        public let id: String
        public let text: String
        public let rangeInCue: UTF16Span
        public let sourceStartMS: Int64
        public let sourceEndMS: Int64?
        public init(id: String, text: String, rangeInCue: UTF16Span,
                    sourceStartMS: Int64, sourceEndMS: Int64?) {
            self.id = id; self.text = text; self.rangeInCue = rangeInCue
            self.sourceStartMS = sourceStartMS; self.sourceEndMS = sourceEndMS
        }
    }
    public struct Cue: Hashable, Codable, Sendable {
        public let id: String
        public let text: String
        public let sourceStartMS: Int64?
        public let sourceEndMS: Int64?
        public let tokens: [Token]
        public let linkedCueID: String?
        public let agentID: String?
        public init(id: String, text: String, sourceStartMS: Int64?, sourceEndMS: Int64?,
                    tokens: [Token], linkedCueID: String?, agentID: String?) {
            self.id = id; self.text = text; self.sourceStartMS = sourceStartMS
            self.sourceEndMS = sourceEndMS; self.tokens = tokens
            self.linkedCueID = linkedCueID; self.agentID = agentID
        }
    }
    public struct Lane: Hashable, Codable, Sendable {
        public let id: String
        public let kind: LaneKind
        public let languageBCP47: String?
        public let cues: [Cue]
        public init(id: String, kind: LaneKind, languageBCP47: String?, cues: [Cue]) {
            self.id = id; self.kind = kind; self.languageBCP47 = languageBCP47; self.cues = cues
        }
    }
    public struct Document: Hashable, Codable, Sendable {
        public let id: UUID
        public let schemaVersion: UInt32
        public let contentHash: String
        public let recording: RecordingIdentity
        public let source: SourceProvenance
        public let originalFormat: Format
        public let timingLevel: TimingLevel
        public let sourceTiming: SourceTiming
        public let lanes: [Lane]
        public let instrumental: Bool
        public init(id: UUID, schemaVersion: UInt32, contentHash: String, recording: RecordingIdentity,
                    source: SourceProvenance, originalFormat: Format, timingLevel: TimingLevel,
                    sourceTiming: SourceTiming, lanes: [Lane], instrumental: Bool) {
            self.id = id; self.schemaVersion = schemaVersion; self.contentHash = contentHash
            self.recording = recording; self.source = source; self.originalFormat = originalFormat
            self.timingLevel = timingLevel; self.sourceTiming = sourceTiming; self.lanes = lanes
            self.instrumental = instrumental
        }
    }

    // Display-only values must never be serialized into the source document as authored timing.
    public struct PresentedCue: Hashable, Sendable {
        public let cueID: String
        public let displayHoldUntilMS: Int64?
        public let activeTokenIDs: Set<String>
        public init(cueID: String, displayHoldUntilMS: Int64?, activeTokenIDs: Set<String>) {
            self.cueID = cueID; self.displayHoldUntilMS = displayHoldUntilMS
            self.activeTokenIDs = activeTokenIDs
        }
    }
    public enum DisplayPhase: String, Sendable {
        case noPlayback, resolving, syncedLine, syncedToken, plainText
        case instrumental, interlude, notFound, sourceUnavailable, positionUnavailable
    }
    public struct Frame: Sendable {
        // nil is the real first-launch/no-playback state; never invent a recording.
        public let selection: Selection?
        public let phase: DisplayPhase
        public let playbackState: PlaybackState // Pause is orthogonal to lyric availability.
        public let lookupMS: Int64?
        public let presentedCues: [PresentedCue]
        public init(selection: Selection?, phase: DisplayPhase, playbackState: PlaybackState,
                    lookupMS: Int64?, presentedCues: [PresentedCue]) {
            self.selection = selection; self.phase = phase; self.playbackState = playbackState
            self.lookupMS = lookupMS; self.presentedCues = presentedCues
        }
    }

    public struct Request: Hashable, Sendable {
        public let requestID: UUID
        public let selection: Selection
        public init(requestID: UUID, selection: Selection) {
            self.requestID = requestID; self.selection = selection
        }
    }
    public struct MatchEvidence: Hashable, Codable, Sendable {
        public let exactProviderIdentity: Bool
        public let titleSimilarity: Double?
        public let mainArtistMatch: Bool?
        public let albumMatch: Bool?
        public let mainArtistConflict: Bool
        public let versionConflict: Bool
        public let durationDeltaMS: Int64?
        public let reasons: [String] // Internal diagnostics, not a user-facing probability.
        public init(exactProviderIdentity: Bool, titleSimilarity: Double?, mainArtistMatch: Bool?,
                    albumMatch: Bool?, mainArtistConflict: Bool, versionConflict: Bool,
                    durationDeltaMS: Int64?, reasons: [String]) {
            self.exactProviderIdentity = exactProviderIdentity
            self.titleSimilarity = titleSimilarity; self.mainArtistMatch = mainArtistMatch
            self.albumMatch = albumMatch
            self.mainArtistConflict = mainArtistConflict; self.versionConflict = versionConflict
            self.durationDeltaMS = durationDeltaMS; self.reasons = reasons
        }
    }
    public struct Candidate: Hashable, Sendable {
        public let request: Request
        public let providerID: String
        public let providerRecordID: String
        public let recording: RecordingIdentity
        public let evidence: MatchEvidence
        public let availableTiming: TimingLevel
        public init(request: Request, providerID: String, providerRecordID: String, recording: RecordingIdentity,
                    evidence: MatchEvidence, availableTiming: TimingLevel) {
            self.request = request; self.providerID = providerID; self.providerRecordID = providerRecordID
            self.recording = recording; self.evidence = evidence; self.availableTiming = availableTiming
        }
    }
    public enum SourceFailure: Error, Sendable {
        case notFound
        case rateLimited(retryAfterSeconds: Int64)
        case transportUnavailable
        case invalidDocument(reason: String)
        case unsupportedFormat
        case unsupportedTimingProfile
        case staleGeneration
        case accessUnavailable
    }
}

// Implement as actors where mutable state/network caches exist. Cancellation is cooperative:
// cancel the Task AND verify Request.selection/session/generation before publishing any result.
public protocol LyricSourceProviding: Sendable {
    func descriptor() async -> LyricDomain.ProviderDescriptor
    func search(_ request: LyricDomain.Request) async throws -> [LyricDomain.Candidate]
    func fetch(_ candidate: LyricDomain.Candidate) async throws -> LyricDomain.Document
}
public protocol LyricDocumentParsing: Sendable {
    func parse(_ bytes: Data, format: LyricDomain.Format,
               recording: LyricDomain.RecordingIdentity,
               source: LyricDomain.SourceProvenance) throws -> LyricDomain.Document
}
public protocol LyricMatching: Sendable {
    func evidence(for candidate: LyricDomain.RecordingIdentity,
                  against recording: LyricDomain.RecordingIdentity) -> LyricDomain.MatchEvidence
    func mayAutomaticallyAccept(_ evidence: LyricDomain.MatchEvidence) -> Bool
}
public protocol LyricTimelineProjecting: Sendable {
    // Use anchor + monotonic elapsed*rate, not frame-delta accumulation. Rebase on seek/wake.
    // Unknown/stale position must not be made to look synchronized. Apply only understood offsets.
    func frame(anchor: LyricDomain.PlaybackAnchor, at: LyricDomain.MonotonicStamp,
               document: LyricDomain.Document?, adjustment: LyricDomain.UserTimingAdjustment?)
        throws -> LyricDomain.Frame
}
