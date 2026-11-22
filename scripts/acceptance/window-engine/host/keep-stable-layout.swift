// Operator for an explicitly requested single-version upgrade. Uses the product's journal and locks.
import AppKit
import CryptoKit
import Darwin
import NearpaneCore
@testable import NearpaneUI

private struct Refusal: Error { let reason: String; init(_ reason: String) { self.reason = reason } }
private func insist(_ value: Bool, _ reason: String) throws {
    if !value { throw Refusal(reason) }
}
private func data(_ url: URL) throws -> Data {
    try ProfileLease.checkPath(url)
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard fd >= 0 else { throw Refusal("requiredFileUnavailable") }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? file.close() }
    var info = stat()
    try insist(fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid()
               && info.st_nlink == 1 && info.st_size > 0 && info.st_size <= 1_048_576, "untrustedJournalFile")
    let bytes = try file.read(upToCount: 1_048_577) ?? Data()
    try insist(bytes.count == info.st_size, "partialJournalFile")
    return bytes
}
private func sha(_ value: Data) -> String {
    SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
}
private func birth(_ pid: pid_t) throws -> UInt64 {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout.size(ofValue: info))
    try insist(proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_uid == getuid()
               && info.pbi_pid == UInt32(pid), "windowProcessUnavailable")
    return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
}
private struct WindowRead: Encodable, Equatable {
    let pid: Int32, birth: UInt64, window: UInt32, frame: SurfaceRect
}
@MainActor private func sample(_ entry: OrdinaryJournal.Entry) throws -> WindowRead {
    let id = entry.id
    try insist(try birth(id.pid) == id.launch &&
               NSRunningApplication(processIdentifier: id.pid)?.bundleIdentifier == entry.bundle, "windowOwnerChanged")
    let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id.number) as? [[String: Any]]
    guard let rows, rows.count == 1, let row = rows.first,
          row[kCGWindowOwnerPID as String] as? Int32 == id.pid, row[kCGWindowNumber as String] as? UInt32 == id.number,
          row[kCGWindowLayer as String] as? Int == 0,
          let raw = row[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: raw),
          [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite),
          rect.width > 0, rect.height > 0, try birth(id.pid) == id.launch else { throw Refusal("exactWindowUnavailable") }
    return WindowRead(pid: id.pid, birth: id.launch, window: id.number,
                      frame: SurfaceRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height))
}

@main enum KeepStableLayout {
    @MainActor static func run(_ args: [String]) throws -> [String: Any] {
        guard args.count == 4, ["--check", "--keep-current"].contains(args[0]), getuid() == geteuid(), getuid() > 0,
              let home = getpwuid(getuid())?.pointee.pw_dir else { throw Refusal("expectedUpgradeArguments") }
        let work = URL(fileURLWithPath: args[1], isDirectory: true)
        let indexDigest = args[2], journalDigest = args[3]
        try insist(work.deletingLastPathComponent().path == "/private/tmp" && work.lastPathComponent.hasPrefix("nearpane-host-inplace."),
                   "expectedPrivateUpgradeBackup")
        let profile = URL(fileURLWithPath: String(cString: home)).appendingPathComponent("Library/Application Support/Nearpane Alpha Profiles")
        let indexFile = profile.appendingPathComponent("profile-index.json"), index = try data(indexFile)
        guard sha(index) == indexDigest, let pointer = try JSONSerialization.jsonObject(with: index) as? [String: Any],
              let active = pointer["active"] as? String, UUID(uuidString: active)?.uuidString.lowercased() == active
        else { throw Refusal("activeGenerationChanged") }
        let relative = "generations/" + active
        let journal = OrdinaryJournal(support: profile.appendingPathComponent(relative))
        let sessionLock = try journal.lock()
        defer { withExtendedLifetime(sessionLock) {} }
        let bytes = try data(journal.file)
        let backup = work.appendingPathComponent("backup/profile-generations/" + relative + "/WorkRect/ordinary/journal.json")
        try insist(sha(bytes) == journalDigest && (try data(backup)) == bytes, "journalOrOriginalBackupChanged")
        let record = try JSONDecoder().decode(OrdinaryJournal.Record.self, from: bytes)
        let reserved = try journal.reservedWindows()
        try insist(!reserved.isEmpty && reserved.count == record.entries.count, "ambiguousReservedWindows")
        var locks = [OrdinaryFileLease]()
        defer { withExtendedLifetime(locks) {} }
        for e in record.entries {
            locks.append(try OrdinaryFileLease.forWindow(e.id))
            try insist(e.intended == nil, "outstandingWriteIntent")
            if let op = e.operation {
                let receipt = try JSONDecoder().decode(OrdinaryJournal.Receipt.self,
                    from: data(journal.directory.appendingPathComponent("action-" + op.uuidString + ".json")))
                try insist(receipt.session == record.session && receipt.id == e.id && receipt.operation == op
                           && receipt.readback.second.cgFrame == receipt.requested && receipt.readback.second.axFrame == receipt.requested,
                           "lastWriteNotConfirmed")
            }
        }
        let files = try FileManager.default.contentsOfDirectory(at: journal.directory, includingPropertiesForKeys: nil)
        for file in files where file.lastPathComponent.hasPrefix("incomplete-") && file.pathExtension == "json" {
            let incomplete = try JSONDecoder().decode(OrdinaryJournal.IncompleteWrite.self, from: data(file))
            try insist(incomplete.session != record.session, "incompleteWriteInCurrentJournal")
        }
        let first = try record.entries.map(sample)
        let started = ProcessInfo.processInfo.systemUptime
        Thread.sleep(forTimeInterval: 0.2)
        let second = try record.entries.map(sample)
        try insist(first == second && (try data(indexFile)) == index && (try data(journal.file)) == bytes,
                   "liveIdentityFrameOrJournalChanged")
        var result: [String: Any] = ["status": "PASS", "scope": "stableOrdinaryJournal",
            "windowWrites": 0, "journalSHA256": journalDigest, "indexSHA256": indexDigest,
            "ordinarySessionLock": true, "windowLocksAcquired": locks.count,
            "sampleInterval": ProcessInfo.processInfo.systemUptime - started,
            "reads": try JSONSerialization.jsonObject(with: JSONEncoder().encode([first, second])),
            "archived": false]
        if args[0] == "--keep-current" {
            try journal.archive(as: "kept-current")
            let after = try FileManager.default.contentsOfDirectory(at: journal.directory, includingPropertiesForKeys: nil)
            let new = after.filter { $0.lastPathComponent.hasPrefix("kept-current-") && !files.contains($0) }
            guard new.count == 1, try data(new[0]) == bytes, !journal.exists else { throw Refusal("archiveReadbackUncertain") }
            result["archived"] = true
            result["archive"] = new[0].lastPathComponent
            result["retainedSHA256"] = sha(try data(new[0]))
        }
        return result
    }
    @MainActor static func main() {
        do {
            let result = try run(Array(CommandLine.arguments.dropFirst()))
            try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
            print()
        } catch {
            let reason = (error as? Refusal)?.reason ?? String(describing: error)
            let result = ["status": "UNKNOWN", "reason": reason, "windowWrites": 0] as [String: Any]
            if let raw = try? JSONSerialization.data(withJSONObject: result) { FileHandle.standardOutput.write(raw) }
            exit(2)
        }
    }
}
