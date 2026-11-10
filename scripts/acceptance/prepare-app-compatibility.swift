import AppKit
import CoreGraphics
import CryptoKit
import Foundation

// Static bundle inspection and locally generated blank documents only. No launch, AX or Apple Events.
struct Application: Codable {
    let name, bundleID, version, build: String
    let runningInstances: Int
    let files: [String]
}
struct Asset: Codable, Equatable {
    let name, sha256: String
    let filesystem, inode: UInt64
}
struct Preparation: Codable {
    let session: UUID
    let system: String
    let apps: [Application]
    let assets: [Asset]
}
enum PreparationError: Error { case arguments, installation, signature, asset, directory }

func asset(at url: URL) throws -> Asset {
    guard url.path == url.resolvingSymlinksInPath().path else { throw PreparationError.asset }
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
          let inode = attributes[.systemFileNumber] as? NSNumber,
          let filesystem = attributes[.systemNumber] as? NSNumber else { throw PreparationError.asset }
    let bytes = try Data(contentsOf: url)
    return Asset(name: url.lastPathComponent, sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                 filesystem: filesystem.uint64Value, inode: inode.uint64Value)
}

func prepare() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    let fm = FileManager.default
    let root = URL(fileURLWithPath: fm.currentDirectoryPath)
    guard fm.fileExists(atPath: root.appendingPathComponent("Dependencies/domains.lock.json").path) else {
        throw PreparationError.directory
    }
    let base = root.appendingPathComponent("build/verification/p47")
    guard base.standardizedFileURL.path == base.resolvingSymlinksInPath().path else { throw PreparationError.directory }
    if args.count == 2, args[0] == "--verify", let id = UUID(uuidString: args[1]), id.uuidString.lowercased() == args[1] {
        let dir = base.appendingPathComponent(args[1])
        let record = dir.appendingPathComponent("preparation.json")
        guard record.path == record.resolvingSymlinksInPath().path else { throw PreparationError.directory }
        let receipt = try JSONDecoder().decode(Preparation.self, from: Data(contentsOf: record))
        let names = ["blank.txt", "blank-a.pdf", "blank-b.pdf"]
        guard receipt.session == id, receipt.assets.map(\.name) == names else { throw PreparationError.asset }
        for stored in receipt.assets {
            guard try asset(at: dir.appendingPathComponent(stored.name)) == stored else { throw PreparationError.asset }
        }
        print("Prepared asset identities and hashes match.")
        return
    }
    guard args.isEmpty else { throw PreparationError.arguments }
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    let session = UUID(), dir = base.appendingPathComponent(session.uuidString.lowercased())
    guard mkdir(dir.path, 0o700) == 0 else { throw PreparationError.directory }

    let text = dir.appendingPathComponent("blank.txt")
    try Data().write(to: text, options: .withoutOverwriting)
    var assets = [try asset(at: text)]
    for name in ["blank-a.pdf", "blank-b.pdf"] {
        let url = dir.appendingPathComponent(name)
        var bounds = CGRect(x: 0, y: 0, width: 256, height: 256)
        let info = [kCGPDFContextTitle as String: session.uuidString + "/" + name] as CFDictionary
        guard let pdf = CGContext(url as CFURL, mediaBox: &bounds, info) else { throw PreparationError.asset }
        pdf.beginPDFPage(nil); pdf.endPDFPage(); pdf.closePDF()
        guard let doc = CGPDFDocument(url as CFURL), doc.numberOfPages == 1 else { throw PreparationError.asset }
        assets.append(try asset(at: url))
    }
    var apps = [Application]()
    for (name, id, files) in [("TextEdit", "com.apple.TextEdit", ["blank.txt"]),
                              ("Calculator", "com.apple.calculator", []),
                              ("Preview", "com.apple.Preview", ["blank-a.pdf", "blank-b.pdf"])] {
        let url = URL(fileURLWithPath: "/System/Applications/\(name).app")
        guard let bundle = Bundle(url: url), bundle.bundleIdentifier == id,
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { throw PreparationError.installation }
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        check.arguments = ["--verify", "--strict", "-R=anchor apple and identifier \"\(id)\"", url.path]
        try check.run(); check.waitUntilExit()
        guard check.terminationStatus == 0 else { throw PreparationError.signature }
        apps.append(.init(name: name, bundleID: id, version: version, build: build,
                          runningInstances: NSRunningApplication.runningApplications(withBundleIdentifier: id).count,
                          files: files))
    }
    let prepared = Preparation(session: session, system: ProcessInfo.processInfo.operatingSystemVersionString, apps: apps, assets: assets)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(prepared).write(to: dir.appendingPathComponent("preparation.json"), options: .withoutOverwriting)
    print(dir.path)
}

do { try prepare() }
catch {
    FileHandle.standardError.write(Data("Compatibility preparation refused: \(error)\n".utf8))
    exit(1)
}
