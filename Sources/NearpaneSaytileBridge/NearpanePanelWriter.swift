import Foundation

/// A synchronous editor connection under the open voice store's process lock.
/// TextKit receives a committed revision before accepting the next keystroke.
@MainActor
package final class NearpanePanelWriter {
    private let db: StoreDatabase

    package init(store: SaytileStore) throws {
        let url = store.directory.appendingPathComponent("Saytile.sqlite")
        for suffix in ["", "-wal", "-shm"] {
            try StorePath.rejectSymbolicLink(URL(fileURLWithPath: url.path + suffix))
        }
        guard FileManager.default.fileExists(atPath: url.path) else { throw StoreError.invalidPath }
        db = try StoreDatabase(url: url)
        try db.execute("PRAGMA busy_timeout=120")
        try db.execute("PRAGMA foreign_keys=ON")
        try db.execute("PRAGMA synchronous=FULL")
    }

    package func apply(_ edits: [PanelRowEdit], visible: [Recording], at date: Date = Date()) throws -> [Recording] {
        let positions = Dictionary(uniqueKeysWithValues: visible.enumerated().map { ($0.element.id, $0.offset) })
        var updated = visible
        for edit in edits where edit.before != nil && positions[edit.id] == nil {
            throw StoreError.missingRecording
        }
        try db.transaction {
            let revisions = try SaytileStore.writePanelEdits(edits, to: db, at: date)
            for edit in edits {
                guard let revision = revisions[edit.id] else { throw StoreError.missingRevision }
                let index = positions[edit.id]
                let old = index.map { visible[$0] }
                let row = Recording(id: edit.id, createdAt: old?.createdAt ?? date,
                    text: edit.after, preferredRevisionID: revision, duration: old?.duration ?? 0,
                    isPinned: old?.isPinned ?? false, audioState: old?.audioState ?? .deleted,
                    recognitionState: old?.recognitionState ?? .completed, isRecording: old?.isRecording ?? false,
                    lastError: old?.lastError, sampleRate: old?.sampleRate ?? 16_000)
                if let index { updated[index] = row }
                else { updated.append(row) }
            }
        }
        if updated.count != visible.count {
            // The local clock may have moved backwards since the preceding phrase.
            updated.sort {
                $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
            }
        }
        return updated
    }
}
