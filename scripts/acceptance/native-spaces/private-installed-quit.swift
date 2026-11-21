// Terminate through the normal app delegate after binding the signed live process and its kernel generation.
import AppKit
import Darwin
import Security

let args = CommandLine.arguments
guard args.count == 5, let pid = Int32(args[1]), let seconds = UInt64(args[2]),
      let micros = UInt64(args[3]), pid > 1 else { exit(2) }

func sameGeneration() -> Bool {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout.size(ofValue: info))
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size &&
           info.pbi_pid == UInt32(pid) && info.pbi_uid == getuid() &&
           info.pbi_start_tvsec == seconds && info.pbi_start_tvusec == micros
}

func liveHash() -> String? {
    var live: SecCode?
    var code: SecStaticCode?
    var signing: CFDictionary?
    guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: pid] as CFDictionary,
                                         [], &live) == errSecSuccess, let live,
          SecCodeCheckValidity(live, [], nil) == errSecSuccess,
          SecCodeCopyStaticCode(live, [], &code) == errSecSuccess, let code,
          SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &signing) == errSecSuccess,
          let fields = signing as? [String: Any], let hash = fields[kSecCodeInfoUnique as String] as? Data
    else { return nil }
    return hash.map { String(format: "%02x", $0) }.joined()
}

guard sameGeneration(), let app = NSRunningApplication(processIdentifier: pid),
      app.bundleIdentifier == "com.holdsnow.nearpane.alpha",
      app.bundleURL?.standardizedFileURL.path == "/Applications/Nearpane.app",
      app.executableURL?.standardizedFileURL.path == "/Applications/Nearpane.app/Contents/MacOS/NearpaneHost",
      liveHash() == args[4], sameGeneration(), app.terminate() else { exit(3) }
