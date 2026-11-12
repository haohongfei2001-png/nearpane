import Foundation
import SaytileKit
import SaytileVoiceUI

/// Present the host's v5 archive in the same document used by the standalone panel.
struct VoiceHistoryEntry: GroupedVoiceTranscriptEntry {
    let id: UUID
    let position: Int64
    let displayText: String
    let group: Int64
    let groupStart: Date
    let groupDay: String
    let groupUTCOffset: Int
}

struct VoiceHistoryProjection: Equatable {
    static let idleInterval: TimeInterval = 120
    let entries: [VoiceHistoryEntry]
    let document: PanelTimelineDocument<VoiceHistoryEntry>
    let copyText: String

    init(_ rows: [Recording] = [], startPosition: Int = 0, hasEarlier: Bool = false, calendar: Calendar = .current) {
        var entries: [VoiceHistoryEntry] = []
        var group = Int64(startPosition)
        var start = Date.distantPast
        var day = ""
        var offset = 0
        var previous: Recording?
        for (index, row) in rows.enumerated() {
            let position = Int64(startPosition + index)
            if previous.map({ !row.nearpaneContinues($0, idleInterval: Self.idleInterval, calendar: calendar) }) ?? true {
                group = position
                start = row.createdAt
                let civil = calendar.dateComponents([.year, .month, .day], from: start)
                day = String(format: "%04d-%02d-%02d", civil.year ?? 0, civil.month ?? 0, civil.day ?? 0)
                offset = calendar.timeZone.secondsFromGMT(for: start)
            }
            entries.append(.init(id: row.id, position: position, displayText: row.text, group: group,
                                 groupStart: start, groupDay: day, groupUTCOffset: offset))
            previous = row
        }
        self.entries = entries
        document = PanelTimelineDocument(entries: entries, older: hasEarlier)
        copyText = VoiceTranscriptFlow.join(entries.filter { $0.group == group }.map(\.displayText))
    }
}
