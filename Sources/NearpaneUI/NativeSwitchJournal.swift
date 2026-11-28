import Foundation
import Darwin
import NearpaneCore

/// Per-protocol, per-OS-build write-ahead record. A lost reply or Host restart leaves the action stopped.
struct NativeSwitchJournal {
    private let directory: URL
    private let pending: URL
    struct Record: Codable {
        let intent: NativeSpaceCommand
        let result: NativeSpaceReply
        let finishedAt: Date
    }

    init(directory: URL) {
        self.directory = directory
        pending = directory.appendingPathComponent("pending.json")
    }

    static func installed() -> Self {
        // Darwin's build is obtained separately from its release, which can span point updates.
        var size = 0
        let name = "kern.osversion"
        var build = "unknown"
        if sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1, size <= 128 {
            var bytes = [CChar](repeating: 0, count: size)
            if sysctlbyname(name, &bytes, &size, nil, 0) == 0 {
                let value = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if value.allSatisfy({ $0.isLetter || $0.isNumber }) { build = value }
            }
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Self(directory: support.appendingPathComponent("Nearpane/NativeSwitch/dock-v1-" + build))
    }

    var suspended: Bool { FileManager.default.fileExists(atPath: pending.path) }

    func begin(_ request: NativeSpaceCommand) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(request).write(to: pending, options: .withoutOverwriting)
    }

    func finish(_ request: NativeSpaceCommand, result: NativeSpaceReply) throws {
        let manager = FileManager.default
        let owner = try JSONDecoder().decode(NativeSpaceCommand.self, from: Data(contentsOf: pending))
        guard owner.id == request.id, result.id == request.id else { throw CocoaError(.fileReadCorruptFile) }
        let record = Record(intent: request, result: result, finishedAt: Date())
        let file = directory.appendingPathComponent(request.id.uuidString).appendingPathExtension("json")
        try JSONEncoder().encode(record).write(to: file, options: .withoutOverwriting)
        if result.state == .confirmed || (result.state == .failed && result.submittedSteps == 0) {
            try manager.removeItem(at: pending)
        }
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
            .filter { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
        if files.count > 80 {
            let dated = try files.map { ($0, try $0.resourceValues(forKeys: keys).contentModificationDate ?? .distantPast) }
            for (old, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(80) { try manager.removeItem(at: old) }
        }
    }
}
