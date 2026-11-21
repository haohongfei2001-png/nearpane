import AppKit
import Foundation

struct SavedTrayFile: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let savedAt: Date
}

/// A completed import is one uniquely named directory. Hiding a tile never removes its file.
actor TrayFileStore {
    let root: URL
    init(root: URL) { self.root = root }

    func save(_ source: URL) throws -> SavedTrayFile {
        guard source.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadUnsupportedScheme) }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let id = UUID()
        let stage = root.appendingPathComponent("." + id.uuidString, isDirectory: true)
        let final = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { if fm.fileExists(atPath: stage.path) { try? fm.removeItem(at: stage) } }
        var failure: NSError?
        var copied: Result<Void, Error>?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &failure) { url in
            copied = Result { try fm.copyItem(at: url, to: stage.appendingPathComponent(source.lastPathComponent)) }
        }
        if let failure { throw failure }
        guard let copied else { throw CocoaError(.fileReadUnknown) }
        try copied.get()
        let now = Date()
        try fm.setAttributes([.modificationDate: now], ofItemAtPath: stage.path)
        try fm.moveItem(at: stage, to: final)
        return .init(id: id, url: final.appendingPathComponent(source.lastPathComponent), savedAt: now)
    }

    func recent(now: Date = .now) throws -> [SavedTrayFile] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        let folders = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        return try folders.compactMap { dir in
            guard let id = UUID(uuidString: dir.lastPathComponent) else { return nil }
            let attrs = try dir.resourceValues(forKeys: keys)
            guard attrs.isDirectory == true, attrs.isSymbolicLink != true, let date = attrs.contentModificationDate,
                  date.addingTimeInterval(60) > now else { return nil }
            let files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            guard files.count == 1 else { return nil }
            return SavedTrayFile(id: id, url: files[0], savedAt: date)
        }.sorted { $0.savedAt > $1.savedAt }
    }
}

enum TrayContentSlot: Equatable, Hashable {
    case shot(UUID), camera, folder, file(UUID)

    static func visible(shots: [UUID], files: [UUID], camera: Bool, capacity: Int = 4) -> [Self] {
        let limit = min(4, max(2, capacity))
        let images = shots.map(Self.shot), docs = files.map(Self.file)
        let entry: [Self] = camera ? [.camera] : []
        if images.isEmpty {
            return docs.isEmpty ? entry + [.folder] : entry + Array(docs.prefix(limit - entry.count).reversed())
        }
        if docs.isEmpty {
            let preferred = images + entry + [.folder]
            return preferred.count <= limit ? preferred : Array(images.prefix(limit - entry.count)) + entry
        }
        if limit == 2 { return [images[0], docs[0]] }
        let count = min(images.count, limit - entry.count - 1)
        let remaining = limit - count - entry.count
        let tail = Array(docs.prefix(remaining).reversed())
        return Array(images.prefix(count)) + entry + (tail.count < remaining ? [.folder] : []) + tail
    }
}
