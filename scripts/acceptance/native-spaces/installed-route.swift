// Read Launch Services and the signed identity of enrolled Nearpane processes without launching any app.
import AppKit
import Darwin
import Security

let identifier = "com.holdsnow.nearpane.alpha"
let selected = CommandLine.arguments[1]
let canonical = "/Applications/Nearpane.app"
func location(_ path: String?) -> String {
    if path == selected { return "selected" }
    if path == canonical { return "canonical" }
    return path == nil ? "missing" : "other"
}

func generation(_ pid: pid_t) -> UInt64? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout.size(ofValue: info))
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
          info.pbi_pid == UInt32(pid), info.pbi_uid == getuid(), info.pbi_start_tvsec > 0 else { return nil }
    return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
}

func process(_ pid: pid_t) -> [String: Any] {
    let unknown: [String: Any] = ["pid": pid, "verified": false]
    var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    var guest: SecCode?
    var code: SecStaticCode?
    var info: CFDictionary?
    guard let born = generation(pid), proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0,
          SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: pid] as CFDictionary, [], &guest) == errSecSuccess,
          let guest, SecCodeCheckValidity(guest, [], nil) == errSecSuccess,
          SecCodeCopyStaticCode(guest, [], &code) == errSecSuccess, let code,
          SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let fields = info as? [String: Any], let hash = fields[kSecCodeInfoUnique as String] as? Data,
          let team = fields[kSecCodeInfoTeamIdentifier as String] as? String,
          generation(pid) == born else { return unknown }
    let executable = URL(fileURLWithPath: String(cString: bytes))
    let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
    return ["pid": pid, "birth": born, "location": location(bundle),
            "kernelExecutableMatches": executable.path == bundle + "/Contents/MacOS/NearpaneHost",
            "cdhash": hash.map { String(format: "%02x", $0) }.joined(),
            "identifierMatches": fields[kSecCodeInfoIdentifier as String] as? String == identifier,
            "team": team, "verified": true]
}

let ws = NSWorkspace.shared
let registrations = Set(ws.urlsForApplications(withBundleIdentifier: identifier).map(\.path))
let running = Set(NSRunningApplication.runningApplications(withBundleIdentifier: identifier).map(\.processIdentifier))
let kernelMatches = Set(CommandLine.arguments.dropFirst(2).compactMap(Int32.init))
let result: [String: Any] = [
    "registered": registrations.map { location($0) }.sorted(),
    "preferred": location(ws.urlForApplication(withBundleIdentifier: identifier)?.path),
    "pidSourcesAgree": running == kernelMatches,
    "processes": running.union(kernelMatches).sorted().map(process)
]
print(String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self))
