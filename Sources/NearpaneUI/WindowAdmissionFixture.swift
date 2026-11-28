import Darwin
import Foundation
import NearpaneCore
import Security

struct AdmissionBirth: Codable, Equatable {
    let pid, parent: Int32
    let start: UInt64

    static func read(_ pid: Int32) -> Self? {
        var b = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue: b))
        guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &b, size) == size,
              b.pbi_pid == UInt32(pid), b.pbi_uid == getuid() else { return nil }
        return .init(pid: pid, parent: Int32(b.pbi_ppid), start: b.pbi_start_tvsec * 1_000_000 + b.pbi_start_tvusec)
    }
}

struct AdmissionSafeguards {
    let exclusive: Bool?, recoveryClear: Bool?
    var storedLayout: (layout: ManagedWindowTiler?, originals: [ManagedWindowID:SurfaceRect])? = nil
}

struct AdmissionFixture {
    static let bundle = "org.nearpane.lab.NearpaneFixtureWindows"

    struct Member: Decodable, Equatable {
        let index: Int, id: ManagedWindowID, minimum: SurfaceRect, identifier: String
    }
    struct Owner: Decodable {
        let session: UUID, owner: AdmissionBirth, revision: Int, uptime: Double
        let members: [Member], frames: [SurfaceRect], editTokens: [String:UUID], editing: Bool
    }
    struct Prefs: Decodable { let session: UUID?, blockedReason: String? }
    struct Run: Decodable {
        struct Screens: Decodable { let secondary: String }
        let session: UUID, parent: AdmissionBirth, productManagement: Bool, screens: Screens
    }
    struct Status: Decodable { let blocked: Bool, trusted: Bool }
    struct Journal: Decodable {
        struct Change: Decodable { let member: Member, editToken: UUID? }
        let status: String, display: String, session: UUID, transaction: UUID, owner: AdmissionBirth, changes: [Change]
    }
    struct Layout: Decodable {
        struct Entry: Decodable { let member: Member, initial: SurfaceRect, confirmed: SurfaceRect }
        let layout: ManagedWindowTiler, display: String, session: UUID, owner: AdmissionBirth, windows: [Entry]
    }
    let root, dir: URL
    let owner: Owner, run: Run, prefs: Prefs

    // No directory traversal or symlinks into other profiles. JSON is atomically published by the helpers.
    static func json<T: Decodable>(_ dir: URL, _ name: String) -> T? {
        let file = dir.appendingPathComponent(name)
        guard file.resolvingSymlinksInPath().path == file.path else { return nil }
        let descriptor = open(file.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var s = stat()
        guard fstat(descriptor, &s) == 0, s.st_uid == getuid(), s.st_mode & S_IFMT == S_IFREG,
              s.st_size > 0, s.st_size <= 512_000, let bytes = try? handle.read(upToCount: Int(s.st_size)),
              bytes.count == s.st_size else { return nil }
        return try? JSONDecoder().decode(T.self, from: bytes)
    }
    private static func privateDirectory(_ url: URL) -> Bool {
        var info = stat()
        return url.resolvingSymlinksInPath().path == url.path && lstat(url.path, &info) == 0
            && info.st_uid == getuid() && info.st_mode & S_IFMT == S_IFDIR && info.st_mode & 0o077 == 0
    }
    static func read(_ root: URL) -> Self? {
        guard privateDirectory(root), let prefs: Prefs = json(root,"management.json"), let session = prefs.session else { return nil }
        let dir = root.appendingPathComponent(session.uuidString.lowercased())
        guard privateDirectory(dir), let run: Run = json(dir,"run.json"), run.productManagement, run.session == session,
              let state: Owner = json(dir,"owner.json"), state.session == session,
              run.parent.parent == getpid(), AdmissionBirth.read(run.parent.pid) == run.parent,
              state.owner.parent == run.parent.pid, AdmissionBirth.read(state.owner.pid) == state.owner,
              verifyFixtureCode(state.owner.pid), valid(state, now: ProcessInfo.processInfo.systemUptime) else { return nil }
        return .init(root: root, dir: dir, owner: state, run: run, prefs: prefs)
    }
    static func valid(_ state: Owner, now: Double) -> Bool {
        let members = state.members
        return state.revision >= 0 && now >= state.uptime && now - state.uptime < 2 && members.count <= 32
            && members.count == state.frames.count && Set(members.map(\.index)).count == members.count
            && Set(members.map(\.id.number)).count == members.count && Set(members.map(\.id.element)).count == members.count
            && members.allSatisfy { m in
                (1...32).contains(m.index) && m.id.pid == state.owner.pid && m.id.launch == state.owner.start && m.id.number > 0
                    && m.identifier == state.session.uuidString + "/" + m.id.element.uuidString
                    && state.editTokens[m.identifier] != nil && m.minimum.width > 0 && m.minimum.height > 0
            }
    }
    private static func verifyFixtureCode(_ pid: Int32) -> Bool {
        let expected = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NearpaneFixtureWindows.app/Contents/MacOS/NearpaneFixtureWindows")
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard expected.resolvingSymlinksInPath().path == expected.path, proc_pidpath(pid, &path, UInt32(path.count)) > 0,
              String(decoding: path.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self) == expected.path else { return false }
        var guest: SecCode?, disk: SecStaticCode?, running: SecStaticCode?
        let flags = SecCSFlags()
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: pid] as CFDictionary, flags, &guest) == errSecSuccess,
              let guest, SecCodeCheckValidity(guest, flags, nil) == errSecSuccess,
              SecCodeCopyStaticCode(guest, flags, &running) == errSecSuccess,
              SecStaticCodeCreateWithPath(expected as CFURL, flags, &disk) == errSecSuccess else { return false }
        func cdhash(_ code: SecStaticCode?) -> Data? {
            var info: CFDictionary?
            guard let code, SecCodeCopySigningInformation(code, .init(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
                  let fields = info as? [String:Any], fields[kSecCodeInfoIdentifier as String] as? String == bundle else { return nil }
            return fields[kSecCodeInfoUnique as String] as? Data
        }
        guard let live = cdhash(running), !live.isEmpty else { return false }
        return live == cdhash(disk)
    }
    // These locks describe only our cooperating fixture and supervisor, never arbitrary third-party writers.
    private func writerPresent(_ file: URL) -> Bool? {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return errno == ENOENT ? false : nil }
        defer { close(fd) }
        var s = stat()
        guard fstat(fd,&s) == 0, s.st_uid == getuid(), s.st_mode & S_IFMT == S_IFREG else { return nil }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 { return false }
        return errno == EWOULDBLOCK ? true : nil
    }
    func safeguards() -> AdmissionSafeguards {
        guard let status: Status = Self.json(root,"status.json") else { return .init(exclusive:nil,recoveryClear:nil) }
        let exclusive: Bool? = status.trusted && writerPresent(root.appendingPathComponent("manager.lock")) == true
            ? writerPresent(dir.appendingPathComponent("writer.lock")).map { !$0 } : nil
        if prefs.blockedReason != nil || status.blocked { return .init(exclusive:exclusive,recoveryClear:false) }
        var st = stat()
        let journalPath = dir.appendingPathComponent("journal.json").path
        if lstat(journalPath,&st) != 0 {
            guard errno == ENOENT else { return .init(exclusive:exclusive,recoveryClear:nil) }
            // A surviving layout without its transaction cannot establish an initial frame.
            let fresh = lstat(dir.appendingPathComponent("layout.json").path,&st) == -1 && errno == ENOENT
                && lstat(journalPath,&st) == -1 && errno == ENOENT
            return .init(exclusive:exclusive,recoveryClear:fresh)
        }
        guard let j: Journal = Self.json(dir,"journal.json"), j.session == run.session, j.display == run.screens.secondary,
              j.owner == owner.owner else { return .init(exclusive:exclusive,recoveryClear:nil) }
        guard ["retained","restored"].contains(j.status), let layout = checkedLayout(j),
              let current: Journal = Self.json(dir,"journal.json"), current.transaction == j.transaction,
              current.session == j.session, current.owner == j.owner, current.status == j.status else {
            return .init(exclusive:exclusive,recoveryClear:false)
        }
        return .init(exclusive:exclusive,recoveryClear:true,storedLayout:layout)
    }
    private func checkedLayout(_ j: Journal) -> (layout: ManagedWindowTiler?, originals: [ManagedWindowID:SurfaceRect])? {
        guard let stored: Layout = Self.json(dir,"layout.json"),
              j.session == run.session, j.display == run.screens.secondary, j.owner == owner.owner,
              stored.session == run.session, stored.display == run.screens.secondary, stored.owner == owner.owner,
              Set(stored.windows.map(\.member.id)).count == stored.windows.count,
              Set(stored.windows.map(\.member.id)) == Set(stored.layout.members.map(\.id)) else { return nil }
        var originals = [ManagedWindowID:SurfaceRect]()
        for e in stored.windows {
            guard let i = owner.members.firstIndex(of:e.member), owner.frames[i] == e.confirmed,
                  let edit = owner.editTokens[e.member.identifier],
                  j.changes.contains(where: { $0.member == e.member && $0.editToken == edit }) else { return nil }
            originals[e.member.id] = e.initial
        }
        return (stored.layout,originals)
    }
}
