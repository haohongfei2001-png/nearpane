import Foundation
import CTileLock

public enum TileCoordinationError: Error, Equatable {
    case busy, invalidIdentifier, corruptRegistry, staleGeneration, instanceConflict
    case fileSystem(Int32)
}

public enum TileStorage {
    public static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("HOLDSNOW/TileCoordination/v1", isDirectory: true)
    }
    static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
    }
    static func valid(_ identifier: String) -> Bool {
        !identifier.isEmpty && identifier.utf8.count <= 160 && identifier.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_")
        }
    }
}

/// A lifetime lock, deliberately separate from the short registry transaction lock.
/// The file is never unlinked: replacing the inode would allow two simultaneous owners.
public final class TileSessionLease: @unchecked Sendable {
    private let path: URL
    private let validIdentifier: Bool
    private let mutex = NSLock()
    private var descriptor: Int32 = -1
    public init(moduleID: String = "lyrics", directory: URL? = nil) {
        validIdentifier = TileStorage.valid(moduleID)
        let safe = validIdentifier ? moduleID : "invalid-module"
        self.path = (directory ?? TileStorage.root).appendingPathComponent("session-\(safe).lock")
    }
    public func acquire() throws -> Bool {
        mutex.lock(); defer { mutex.unlock() }
        guard validIdentifier else { throw TileCoordinationError.invalidIdentifier }
        if descriptor >= 0 { return true }
        try TileStorage.prepare(path.deletingLastPathComponent())
        var error: Int32 = 0
        let result = path.path.withCString { lt_lock_acquire($0, &error) }
        if result == -2 { return false }
        guard result >= 0 else { throw TileCoordinationError.fileSystem(error) }
        descriptor = result
        return true
    }
    public func release() {
        mutex.lock(); defer { mutex.unlock() }
        lt_lock_release(descriptor); descriptor = -1
    }
    deinit { lt_lock_release(descriptor) }
}

public enum TileProcess {
    public static func token(for pid: Int32 = ProcessInfo.processInfo.processIdentifier) -> String? {
        var buffer = [CChar](repeating: 0, count: 128)
        let result = buffer.withUnsafeMutableBufferPointer { lt_process_token(pid, $0.baseAddress, $0.count) }
        guard result == 1 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
