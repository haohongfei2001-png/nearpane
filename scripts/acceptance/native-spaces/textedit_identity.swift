import ApplicationServices
import Darwin
import Foundation
import Security

struct TextEditProcessIdentity {
    static let application = URL(fileURLWithPath: "/System/Applications/TextEdit.app", isDirectory: true)
    static let executable = application.appendingPathComponent("Contents/MacOS/TextEdit").resolvingSymlinksInPath()
    let pid: pid_t, uid: uid_t, birth: UInt64
    let hash: String

    static func kernelBirth(_ pid: pid_t) -> UInt64? {
        var console = stat(), info = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard pid > 1, stat("/dev/console", &console) == 0, console.st_uid == getuid(), geteuid() == getuid(),
              proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_pid == UInt32(pid),
              info.pbi_ruid == console.st_uid, info.pbi_uid == console.st_uid, info.pbi_status != UInt32(SZOMB),
              info.pbi_start_tvsec > 0, info.pbi_start_tvusec < 1_000_000,
              proc_pidpath(pid, &path, UInt32(path.count)) > 0, String(cString: path) == executable.path else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

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

    static func systemCodeHash() -> Data? {
        var disk: SecStaticCode?
        guard let appleTextEdit, SecStaticCodeCreateWithPath(executable as CFURL, [], &disk) == errSecSuccess, let disk,
              SecStaticCodeCheckValidity(disk, [], appleTextEdit) == errSecSuccess else { return nil }
        return codeHash(disk)
    }

    static func read(_ pid: pid_t) -> Self? {
        var guest: SecCode?, liveCode: SecStaticCode?
        guard let birth = kernelBirth(pid), let appleTextEdit, let diskHash = systemCodeHash(),
              SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: pid] as CFDictionary, [], &guest) == errSecSuccess,
              let guest, SecCodeCheckValidity(guest, [], appleTextEdit) == errSecSuccess,
              SecCodeCopyStaticCode(guest, [], &liveCode) == errSecSuccess, let liveCode, codeHash(liveCode) == diskHash,
              kernelBirth(pid) == birth else { return nil }
        return Self(pid: pid, uid: getuid(), birth: birth, hash: diskHash.map { String(format: "%02x", $0) }.joined())
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
