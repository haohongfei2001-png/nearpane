#if canImport(SaytileKit)
import AppKit
import SQLite3
import ImageIO
import NearpaneCore
import NearpaneUI
import RiftletCapture
import RiftletCore
import SaytileKit
import UniformTypeIdentifiers

/// Used only by the separately identified development candidate. Publish the first-run
/// directory as one unit so an interrupted seed never duplicates revisions or imports.
enum CandidateProfile {
    static let identifier = "com.holdsnow.nearpane.alpha"
    static var selected: Bool { Bundle.main.bundleIdentifier == identifier }

    static let containerName = "Nearpane Alpha Profiles"

    @MainActor static func open(in parent: URL) async throws -> (ProfileLease, URL) {
        let fm = FileManager.default
        let root = parent.appendingPathComponent(containerName, isDirectory: true)
        try ProfileLease.checkPath(root)
        if !fm.fileExists(atPath: root.path) {
            let stage = parent.appendingPathComponent(".nearpane-alpha-" + UUID().uuidString)
            let id = UUID().uuidString.lowercased()
            let generation = stage.appendingPathComponent("generations/" + id)
            try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: stage) }
            try fm.createDirectory(at: generation, withIntermediateDirectories: true)
            try await seed(at: generation, examples: false)
            let index: [String: Any] = ["format": 1, "active": id, "previous": NSNull(), "imports": [String: String]()]
            try JSONSerialization.data(withJSONObject: index, options: .sortedKeys)
                .write(to: stage.appendingPathComponent("profile-index.json"), options: .withoutOverwriting)
            do { try fm.moveItem(at: stage, to: root) }
            catch { guard fm.fileExists(atPath: root.path) else { throw error } }
        }
        if fm.fileExists(atPath: root.appendingPathComponent("transaction.json").path) {
            _ = try await ProfileHelper.run("recover", root: root)
        }
        let lease = try ProfileLease(root: root)
        let active = try lease.activeGeneration()
        _ = try inspectStores(in: active)
        return (lease, active)
    }

    /// Check both formats before any domain constructor can run its writable migration code.
    static func inspectStores(in root: URL, counts: Bool = false) throws -> [String: Int] {
        var result: [String: Int] = [:]
        for (path, version, table) in [("Nearpane/Voice/Saytile.sqlite", 5, "recordings"),
                                       ("Riftlet/queue.sqlite", 4, "assets")] {
            let url = root.appendingPathComponent(path)
            for suffix in ["", "-wal", "-shm", "-journal"] {
                try ProfileLease.checkPath(URL(fileURLWithPath: url.path + suffix))
            }
            var db: OpaquePointer?
            guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else {
                sqlite3_close(db)
                throw CocoaError(.fileReadCorruptFile)
            }
            defer { sqlite3_close(db) }
            func integer(_ sql: String) throws -> Int {
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw CocoaError(.fileReadCorruptFile) }
                defer { sqlite3_finalize(stmt) }
                guard sqlite3_step(stmt) == SQLITE_ROW else { throw CocoaError(.fileReadCorruptFile) }
                return Int(sqlite3_column_int64(stmt, 0))
            }
            guard try integer("PRAGMA user_version") == version else {
                throw NSError(domain: "Nearpane.Profile", code: 4, userInfo: [NSLocalizedDescriptionKey: "这份资料的数据库格式与当前 Nearpane 不兼容。请使用对应的版本。"])
            }
            if counts { result[table] = try integer("SELECT count(*) FROM " + table) }
        }
        return result
    }

    @MainActor static func prepareFixture(in parent: URL, examples: Bool = false) async throws -> URL {
        let fm = FileManager.default
        let root = parent.appendingPathComponent("support")
        try ProfileLease.checkPath(root)
        if fm.fileExists(atPath: root.path) {
            for name in ["profile.version","Nearpane","Nearpane/Voice","Riftlet","Nearpane/host-configuration.json"] {
                try ProfileLease.checkPath(root.appendingPathComponent(name))
            }
            guard try Data(contentsOf: root.appendingPathComponent("profile.version")) == ProfileLease.marker else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return root
        }
        let stage = parent.appendingPathComponent(".nearpane-fixture-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        try await seed(at: stage, examples: examples)
        try fm.moveItem(at: stage, to: root)
        return root
    }

    @MainActor private static func seed(at stage: URL, examples: Bool) async throws {
        let fm = FileManager.default
        let support = stage.appendingPathComponent("Nearpane")
        let library = stage.appendingPathComponent("Riftlet")
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        try Data().write(to: library.appendingPathComponent("instance.lock"), options: .withoutOverwriting)
        try await seedGallery(library, includeExamples: examples)
        let voice = try SaytileStore(directory: support.appendingPathComponent("Voice"))
        if examples {
            let row = try await voice.createRecording()
            try await voice.finishRecording(id: row.id)
            try await voice.saveEdit(recordingID: row.id, text: "示例手记\n雨停了。沿街的树叶还挂着水珠。")
        }
        try await voice.close()
        var config = HostConfiguration()
        let screens = SystemScreens.geometry()
        config.preferredDisplayID = (screens.dropFirst().first ?? screens.first)?.id
        try FileConfigurationStore(url: support.appendingPathComponent("host-configuration.json")).save(config)
        try ProfileLease.marker.write(to: stage.appendingPathComponent("profile.version"))
    }

    private static func seedGallery(_ root: URL, includeExamples: Bool) async throws {
        let queue = try QueueStore(databaseURL: root.appendingPathComponent("queue.sqlite"))
        guard includeExamples else { return }
        let importer = PrivateAssetImporter(privateRoot: root, store: queue)
        let examples = root.appendingPathComponent("examples")
        try FileManager.default.createDirectory(at: examples, withIntermediateDirectories: false)
        for i in 0..<5 {
            let url = examples.appendingPathComponent("sample-\(i + 1).png")
            guard let c = CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
                  let out = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
            c.setFillColor(red: 0.13, green: 0.25 + 0.09 * Double(i), blue: 0.38, alpha: 1)
            c.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
            c.setStrokeColor(gray: 1, alpha: 0.9)
            c.setLineWidth(3)
            for x in 0...320 {
                let p = CGPoint(x: Double(x), y: 90 + 55 * sin(Double(x) / (16 + 6 * Double(i))))
                if x == 0 { c.move(to: p) } else { c.addLine(to: p) }
            }
            c.strokePath()
            guard let image = c.makeImage() else { throw CocoaError(.fileWriteUnknown) }
            CGImageDestinationAddImage(out, image, nil)
            guard CGImageDestinationFinalize(out) else { throw CocoaError(.fileWriteUnknown) }
            try await importer.importFile(at: url, origin: .synthetic)
        }
    }
}
#endif
