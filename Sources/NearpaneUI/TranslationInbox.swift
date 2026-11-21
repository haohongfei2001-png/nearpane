import Foundation
import NearpaneCore

struct TranslationRequest: Codable, Equatable {
    let id: UUID
    let created: Date
    let source: String
    let hash: String
    let generation: UUID?

    init(_ source: String, generation: UUID?) throws {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, source.utf8.count <= 65_536 else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        id = UUID(); created = Date(); self.source = source
        hash = LocalToolStage.digest(Data(source.utf8)); self.generation = generation
    }
}

/// A Services callback can arrive before the Host finishes opening its profile.
struct TranslationInbox {
    let directory: URL
    let profiles: URL
    init(support: URL) {
        directory = support.appendingPathComponent("Nearpane Translation Inbox", isDirectory: true)
        profiles = support.appendingPathComponent("Nearpane Alpha Profiles", isDirectory: true)
    }
    func target() throws -> UUID? {
        let file = profiles.appendingPathComponent("profile-index.json")
        try ProfileLease.checkPath(file)
        guard FileManager.default.fileExists(atPath: profiles.path) else { return nil }
        struct Index: Decodable { let active: UUID }
        return try JSONDecoder().decode(Index.self, from: Data(contentsOf: file)).active
    }
    private func folder(_ id: UUID?) -> URL {
        directory.appendingPathComponent(id?.uuidString ?? "first-launch", isDirectory: true)
    }

    func append(_ request: TranslationRequest) throws {
        let dest = folder(request.generation)
        try ProfileLease.checkPath(dest)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = dest.appendingPathComponent(request.id.uuidString + ".json")
        try ProfileLease.checkPath(file)
        try JSONEncoder().encode(request).write(to: file, options: .atomic)
    }
    func pending(for generation: UUID) throws -> [TranslationRequest] {
        var roots = [folder(generation)]
        let initial = folder(nil)
        try ProfileLease.checkPath(initial)
        if FileManager.default.fileExists(atPath: initial.path) {
            let adoption = initial.appendingPathComponent("first-generation")
            try ProfileLease.checkPath(adoption)
            if !FileManager.default.fileExists(atPath: adoption.path) {
                try Data(generation.uuidString.utf8).write(to: adoption, options: .withoutOverwriting)
            }
            if try String(contentsOf: adoption, encoding: .utf8) == generation.uuidString { roots.append(initial) }
        }
        var requests: [TranslationRequest] = []
        for root in roots {
            try ProfileLease.checkPath(root)
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            for path in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                guard path.pathExtension == "json", let id = UUID(uuidString: path.deletingPathExtension().lastPathComponent) else { continue }
                try ProfileLease.checkPath(path)
                let item = try JSONDecoder().decode(TranslationRequest.self, from: Data(contentsOf: path))
                guard item.id == id, item.hash == LocalToolStage.digest(Data(item.source.utf8)),
                      folder(item.generation) == root else { throw CocoaError(.fileReadCorruptFile) }
                requests.append(item)
            }
        }
        return requests.sorted { ($0.created, $0.id.uuidString) < ($1.created, $1.id.uuidString) }
    }
    func finish(_ request: TranslationRequest) throws {
        let file = folder(request.generation).appendingPathComponent(request.id.uuidString + ".json")
        try ProfileLease.checkPath(file)
        try FileManager.default.removeItem(at: file)
    }
}
