import Foundation
import LyricCore

enum JSONValue: Codable, Sendable, Equatable {
    case null, bool(Bool), int(Int64), double(Double), string(String)
    case array([JSONValue]), object([String: JSONValue])
    init(from decoder: any Decoder) throws {
        let box = try decoder.singleValueContainer()
        if box.decodeNil() { self = .null }
        else if let value = try? box.decode(Bool.self) { self = .bool(value) }
        else if let value = try? box.decode(Int64.self) { self = .int(value) }
        else if let value = try? box.decode(Double.self) { self = .double(value) }
        else if let value = try? box.decode(String.self) { self = .string(value) }
        else if let value = try? box.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try box.decode([String: JSONValue].self)) }
    }
    func encode(to encoder: any Encoder) throws {
        var box = encoder.singleValueContainer()
        switch self {
        case .null: try box.encodeNil()
        case .bool(let v): try box.encode(v)
        case .int(let v): try box.encode(v)
        case .double(let v): try box.encode(v)
        case .string(let v): try box.encode(v)
        case .array(let v): try box.encode(v)
        case .object(let v): try box.encode(v)
        }
    }
    var string: String? { if case .string(let v) = self { return v }; return nil }
    var integer: Int64? {
        if case .int(let v) = self { return v }
        if case .double(let v) = self, v.isFinite, v.rounded() == v, v >= Double(Int64.min), v < Double(Int64.max) { return Int64(v) }
        return nil
    }
    var number: Double? {
        switch self { case .int(let v): Double(v); case .double(let v): v; default: nil }
    }
    var boolean: Bool? { if case .bool(let v) = self { return v }; return nil }
    var object: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    var array: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
}

struct NDJSONFramer: Sendable {
    private(set) var remainder = Data()
    let limit: Int
    init(limit: Int = 512 * 1024) { self.limit = limit }
    mutating func append(_ bytes: Data) throws -> [Data] {
        guard bytes.count <= limit else { throw PlaybackError.outputLimit }
        remainder.append(bytes)
        var lines: [Data] = []
        while let newline = remainder.firstIndex(of: 10) {
            let count = remainder.distance(from: remainder.startIndex, to: newline)
            guard count <= limit else { throw PlaybackError.outputLimit }
            if count > 0 { lines.append(Data(remainder[..<newline])) }
            remainder.removeSubrange(...newline)
        }
        guard remainder.count <= limit else { throw PlaybackError.outputLimit }
        return lines
    }
}

struct MediaRemoteReducer: Sendable {
    private(set) var payload: [String: JSONValue]?
    mutating func reset() { payload = nil }
    @discardableResult mutating func consume(_ line: Data) throws -> [String: JSONValue]? {
        guard line.count <= 512 * 1024 else { throw PlaybackError.outputLimit }
        guard let envelope = try JSONDecoder().decode(JSONValue.self, from: line).object,
              envelope["type"]?.string == "data",
              let diff = envelope["diff"]?.boolean,
              let update = envelope["payload"]?.object else { throw PlaybackError.malformedPayload }
        if !diff { payload = update.filter { $0.value != .null } }
        else {
            // A restarted/dropped stream must establish a complete baseline.
            guard var previous = payload else { throw PlaybackError.malformedPayload }
            for (key, value) in update {
                if value == .null { previous.removeValue(forKey: key) } else { previous[key] = value }
            }
            payload = previous
        }
        return payload
    }
}

struct MediaRemotePayload: Sendable {
    let fields: [String: JSONValue]
    var player: PlayerID? {
        if let parent = fields["parentApplicationBundleIdentifier"]?.string, let id = PlayerID(bundleID: parent) { return id }
        return fields["bundleIdentifier"]?.string.flatMap(PlayerID.init(bundleID:))
    }
    var pid: Int32? {
        guard let n = fields["processIdentifier"]?.integer, n > 0, n <= Int64(Int32.max) else { return nil }
        return Int32(n)
    }
    var state: LyricDomain.PlaybackState {
        guard let playing = fields["playing"]?.boolean else { return .unknown }
        if playing, fields["playbackRate"]?.number == 0 { return .buffering }
        return playing ? .playing : .paused
    }
    var commandIDs: Set<Int64> {
        Set((fields["supportedCommands"]?.array ?? []).compactMap {
            guard let item = $0.object, item["enabled"]?.boolean == true else { return nil }
            return item["id"]?.integer
        })
    }
    var restricted: Bool { fields["isAdvertisement"]?.boolean == true || fields["prohibitsSkip"]?.boolean == true }
    func capabilities(isCurrent: Bool) -> TransportCapabilities {
        guard isCurrent, pid != nil, state != .unknown else { return .init() }
        let ids = commandIDs
        // 24 is MediaRemote SeekToPlaybackPosition. Missing commands never imply support.
        // Paused MediaRemote seek remains off until a non-resuming route is qualified.
        return .init(canPlay: ids.contains(0), canPause: ids.contains(1),
                     canNext: ids.contains(4) && !restricted, canPrevious: ids.contains(5) && !restricted,
                     canSeek: ids.contains(24) && state == .playing && !restricted && (durationMS ?? 0) > 0
                        && MediaTime.micros(fields["elapsedTimeMicros"]?.integer) != nil)
    }
    var durationMS: Int64? { MediaTime.micros(fields["durationMicros"]?.integer) }
    var artwork: Data? {
        guard let base64 = fields["artworkData"]?.string, base64.utf8.count <= 12 * 1024 * 1024,
              let data = Data(base64Encoded: base64), data.count <= 8 * 1024 * 1024 else { return nil }
        return data
    }
    func observation(process: PlayerProcess, mediaStart: UInt64, isCurrent: Bool,
                     now: LyricDomain.MonotonicStamp = PlaybackClock.now(), wallNow: Date = Date()) -> PlayerObservation? {
        guard player == process.player, let pid else { return nil }
        let duration = durationMS
        let elapsed = MediaTime.micros(fields["elapsedTimeMicros"]?.integer)
        let rawRate = fields["playbackRate"]?.number
        let rate = state == .playing ? ((rawRate?.isFinite == true && rawRate! > 0 && rawRate! <= 8) ? rawRate! : 1) : 0
        let publishesTransientItemUUIDs: Bool
        switch process.player {
        case .qqMusic: publishesTransientItemUUIDs = process.build == "73284" || process.build == "73285"
        case .netease: publishesTransientItemUUIDs = process.build == "3459"
        default: publishesTransientItemUUIDs = false
        }
        // These observed client builds can flip the global playing flag before
        // refreshing the playing anchor. Reusing elapsed would rewind on pause.
        // NetEase 3459 delivered a valid rate-zero anchor in CI43, but retained
        // its seek anchor with rate one in CI44: accept only its refreshed clock.
        // Keep this source-clock rule separate from transient item identity.
        let awaitingPauseAnchor = state == .paused && (rawRate ?? 0) > 0
            && ((process.player == .qqMusic && (process.build == "73284" || process.build == "73285"))
                || (process.player == .netease && process.build == "3459"))
        var currentPosition: Int64? = awaitingPauseAnchor ? nil : elapsed
        if state == .playing {
            // A quiet stream can carry an old *valid* source anchor. Rebase that
            // anchor at the fresh health response, not at the next display frame.
            if let elapsed, let micros = fields["timestampEpochMicros"]?.integer {
                let age = wallNow.timeIntervalSince1970 - Double(micros) / 1_000_000
                if age.isFinite, age >= -2, age <= max(86_400, Double(duration ?? 0) / 1000 + 300) {
                    currentPosition = MediaTime.clampedMilliseconds(Double(elapsed) + max(0, age) * 1000 * rate, duration: duration)
                } else { currentPosition = nil }
            } else { currentPosition = nil } // A missing timestamp is not a new zero anchor.
        }
        var itemID = fields["contentItemIdentifier"]?.string
        let alternateID = fields["uniqueIdentifier"]?.string
        // These observed QQ/NetEase builds refresh content UUIDs during same-
        // track control updates. They identify updates, not catalog recordings.
        // Preserve other IDs and metadata distinctions; leave unknown builds alone.
        if publishesTransientItemUUIDs,
           let value = itemID, UUID(uuidString: value) != nil {
            itemID = alternateID == value ? nil : alternateID
        } else {
            itemID = itemID ?? alternateID
        }
        var controls = capabilities(isCurrent: isCurrent)
        if currentPosition == nil { controls.canSeek = false }
        return PlayerObservation(process: process, mediaPID: pid, mediaProcessStart: mediaStart,
            title: fields["title"]?.string, artist: fields["artist"]?.string, album: fields["album"]?.string,
            platformID: itemID, durationMS: duration, positionMS: currentPosition, state: state, rate: rate,
            stamp: now, capabilities: controls, artwork: artwork, artworkURL: nil,
            sourceIsCurrent: isCurrent, quality: currentPosition == nil ? .unavailable : .coarseSourceAnchor,
            restricted: restricted, clockNeedsReanchor: awaitingPauseAnchor)
    }
    static func decodeGet(_ data: Data, target: PlayerID?) throws -> [MediaRemotePayload] {
        guard data.count <= 12 * 1024 * 1024 else { throw PlaybackError.outputLimit }
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        if value == .null && target == nil { return [] }
        if target != nil {
            guard let list = value.array, list.count <= 32 else { throw PlaybackError.malformedPayload }
            return try list.map {
                guard let object = $0.object else { throw PlaybackError.malformedPayload }
                return MediaRemotePayload(fields: object)
            }
        }
        guard let object = value.object else { throw PlaybackError.malformedPayload }
        return [MediaRemotePayload(fields: object)]
    }
}
