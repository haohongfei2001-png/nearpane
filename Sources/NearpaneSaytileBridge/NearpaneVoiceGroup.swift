import Foundation

extension Recording {
    public func nearpaneContinues(_ previous: Recording, idleInterval: TimeInterval, calendar: Calendar) -> Bool {
        calendar.isDate(createdAt, inSameDayAs: previous.createdAt) &&
            createdAt.timeIntervalSince(previous.createdAt.addingTimeInterval(max(0, previous.duration))) < idleInterval
    }
}

extension SaytileStore {
    /// All pages are read on the store actor in a single synchronous turn. Only
    /// one page of recordings and the text the user actually wants are retained.
    public func nearpaneGroupText(through tail: UUID, snapshot: [UUID: String],
                                  idleInterval: TimeInterval, calendar: Calendar = .current) throws -> String {
        var next: Recording?
        var offset = 0
        var pieces: [String] = []
        let batchSize = 60
        while true {
            let rows = try listPanelRecordings(createdSince: .distantPast, includingIDs: [], limit: batchSize, offset: offset)
            for row in rows {
                if next == nil && row.id != tail { continue }
                if let next, !next.nearpaneContinues(row, idleInterval: idleInterval, calendar: calendar) {
                    return pieces.reversed().joined(separator: "\n")
                }
                let text = snapshot[row.id] ?? row.text
                if !text.isEmpty { pieces.append(text) }
                next = row
            }
            if rows.count < batchSize { return pieces.reversed().joined(separator: "\n") }
            offset += rows.count
        }
    }
}
