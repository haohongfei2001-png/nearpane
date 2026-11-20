import ApplicationServices
import Darwin
import Foundation
import Security

struct TextEditIdentityRefusal: Error {
    let stage: String
    let detail: String
    init(_ stage: String, _ detail: String) { self.stage = stage; self.detail = detail }
    var reason: String { "TextEdit \(stage): \(detail)" }
}

struct TextEditArchitecture: Codable, Equatable {
    let cpu: Int32, subtype: Int32
    static func read(_ pid: pid_t) throws -> Self {
        var info = proc_archinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        guard proc_pidinfo(pid, PROC_PIDARCHINFO, 0, &info, size) == size, info.p_cputype > 0 else {
            throw TextEditIdentityRefusal("kernelArchitecture", "running Mach-O slice unavailable")
        }
        return Self(cpu: info.p_cputype, subtype: info.p_cpusubtype)
    }
}

struct TextEditProcessIdentity {
    static let application = URL(fileURLWithPath: "/System/Applications/TextEdit.app", isDirectory: true)
    static let executable = application.appendingPathComponent("Contents/MacOS/TextEdit").resolvingSymlinksInPath()
    let pid: pid_t, uid: uid_t, birth: UInt64
    let hash: String, architecture: TextEditArchitecture

    static func consoleBirth(_ pid: pid_t) throws -> UInt64 {
        var console = stat(), info = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        guard stat("/dev/console", &console) == 0, console.st_uid == getuid(), geteuid() == getuid() else {
            throw TextEditIdentityRefusal("consoleUID", "observer does not match the physical console user")
        }
        guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_pid == UInt32(pid),
              info.pbi_status != UInt32(SZOMB), info.pbi_start_tvsec > 0, info.pbi_start_tvusec < 1_000_000 else {
            throw TextEditIdentityRefusal("kernelBirth", "live PID and birth are unavailable")
        }
        guard info.pbi_ruid == console.st_uid, info.pbi_uid == console.st_uid else {
            throw TextEditIdentityRefusal("processUID", "process does not belong to the console user")
        }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    static func requireKernelBirth(_ pid: pid_t) throws -> UInt64 {
        let birth = try consoleBirth(pid)
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0, String(cString: path) == executable.path else {
            throw TextEditIdentityRefusal("kernelExecutable", "process is not the system TextEdit executable")
        }
        return birth
    }

    static func kernelBirth(_ pid: pid_t) -> UInt64? { try? requireKernelBirth(pid) }

    private static let appleTextEdit: SecRequirement? = {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple and identifier \"com.apple.TextEdit\"" as CFString,
                                              [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }()

    private static func codeHash(_ code: SecStaticCode) -> Data? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let hash = (information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data, !hash.isEmpty else { return nil }
        return hash
    }

    static func systemCodeHash(for arch: TextEditArchitecture) throws -> Data {
        var disk: SecStaticCode?
        let attributes = [kSecCodeAttributeArchitecture as String: NSNumber(value: arch.cpu),
                          kSecCodeAttributeSubarchitecture as String: NSNumber(value: arch.subtype)] as CFDictionary
        guard let appleTextEdit, SecStaticCodeCreateWithPathAndAttributes(executable as CFURL, [], attributes, &disk) == errSecSuccess,
              let disk, SecStaticCodeCheckValidity(disk, [], appleTextEdit) == errSecSuccess, let hash = codeHash(disk) else {
            throw TextEditIdentityRefusal("signedDiskSlice", "Apple signature or CDHash unavailable for the running architecture")
        }
        return hash
    }

    static func read(_ pid: pid_t) throws -> Self {
        let birth = try requireKernelBirth(pid), arch = try TextEditArchitecture.read(pid)
        let diskHash = try systemCodeHash(for: arch)
        var guest: SecCode?, liveCode: SecStaticCode?
        guard let appleTextEdit,
              SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: pid] as CFDictionary, [], &guest) == errSecSuccess,
              let guest, SecCodeCheckValidity(guest, [], appleTextEdit) == errSecSuccess,
              SecCodeCopyStaticCode(guest, [], &liveCode) == errSecSuccess, let liveCode, let liveHash = codeHash(liveCode) else {
            throw TextEditIdentityRefusal("signedProcess", "running Apple signature or CDHash unavailable")
        }
        guard liveHash == diskHash else { throw TextEditIdentityRefusal("matchingCDHash", "running and same-slice disk CDHashes differ") }
        guard try requireKernelBirth(pid) == birth, try TextEditArchitecture.read(pid) == arch else {
            throw TextEditIdentityRefusal("stableGeneration", "process or architecture changed during verification")
        }
        return Self(pid: pid, uid: getuid(), birth: birth, hash: diskHash.map { String(format: "%02x", $0) }.joined(), architecture: arch)
    }
}

// The global focused application is permission to inspect its focus only when it identifies
// the enrolled PID. A background application's own AXFocusedWindow can remain populated.
struct TextEditFocusReader<Element> {
    let read: (Element, String) -> Element?
    let owner: (Element) -> pid_t?
    let same: (Element, Element) -> Bool

    func indices(system: Element, root: Element, pid: pid_t, windows: [Element], editor: Element? = nil) -> (focused: Int, main: Int?)? {
        func owned(_ source: Element, _ attribute: String) -> Element? {
            guard let element = read(source, attribute), owner(element) == pid else { return nil }
            return element
        }
        guard owner(root) == pid, let app = owned(system, kAXFocusedApplicationAttribute),
              let key = owned(app, kAXFocusedWindowAttribute), let direct = owned(root, kAXFocusedWindowAttribute), same(key, direct),
              let focused = windows.firstIndex(where: { same($0, key) }) else { return nil }
        let main = owned(root, kAXMainWindowAttribute).flatMap { window in windows.firstIndex { same($0, window) } }
        if let editor {
            guard main == focused, owner(editor) == pid,
                  let appEditor = owned(root, kAXFocusedUIElementAttribute), same(appEditor, editor),
                  let systemEditor = owned(system, kAXFocusedUIElementAttribute), same(systemEditor, editor) else { return nil }
        }
        guard let lastApp = owned(system, kAXFocusedApplicationAttribute), same(app, lastApp),
              let lastKey = owned(lastApp, kAXFocusedWindowAttribute), same(key, lastKey) else { return nil }
        if let editor {
            guard let lastMain = owned(lastApp, kAXMainWindowAttribute), same(lastMain, lastKey),
                  let lastEditor = owned(system, kAXFocusedUIElementAttribute), same(lastEditor, editor) else { return nil }
        }
        return (focused, main)
    }
}
