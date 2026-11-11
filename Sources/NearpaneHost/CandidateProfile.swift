#if canImport(SaytileKit)
import AppKit
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
    static let identifier = "com.holdsnow.nearpane.candidate.p52"
    static var selected: Bool { Bundle.main.bundleIdentifier == identifier }

    @MainActor static func prepare(in parent: URL, acceptance: Bool = false, includeExamples: Bool = false) async throws -> URL {
        let fm = FileManager.default
        let root = parent.appendingPathComponent(acceptance ? "support" : "Nearpane Alpha P5.2")
        guard root.standardizedFileURL.path == root.resolvingSymlinksInPath().path else { throw CocoaError(.fileReadNoPermission) }
        let marker = Data("Nearpane P5.2\n".utf8)
        if fm.fileExists(atPath: root.path) {
            for name in ["profile.version","Nearpane","Nearpane/Voice","Riftlet","Nearpane/host-configuration.json"] {
                let url = root.appendingPathComponent(name)
                guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().path else { throw CocoaError(.fileReadNoPermission) }
            }
            guard try Data(contentsOf: root.appendingPathComponent("profile.version")) == marker else { throw CocoaError(.fileReadCorruptFile) }
            return root
        }
        let stage = parent.appendingPathComponent(".nearpane-alpha-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        let support = stage.appendingPathComponent("Nearpane")
        let library = stage.appendingPathComponent("Riftlet")
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        try Data().write(to: library.appendingPathComponent("instance.lock"), options: .withoutOverwriting)
        let seedExamples = acceptance && includeExamples
        try await seedGallery(library, includeExamples: seedExamples)
        let voice = try SaytileStore(directory: support.appendingPathComponent("Voice"))
        if seedExamples {
            let row = try await voice.createRecording()
            try await voice.finishRecording(id: row.id)
            try await voice.saveEdit(recordingID: row.id, text: "示例手记\n雨停了。沿街的树叶还挂着水珠。")
        }
        try await voice.close()
        var config = HostConfiguration()
        let screens = SystemScreens.geometry()
        config.preferredDisplayID = (screens.dropFirst().first ?? screens.first)?.id
        try FileConfigurationStore(url: support.appendingPathComponent("host-configuration.json")).save(config)
        try marker.write(to: stage.appendingPathComponent("profile.version"))
        try fm.moveItem(at: stage, to: root)
        return root
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
