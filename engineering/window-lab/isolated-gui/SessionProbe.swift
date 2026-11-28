// Read-only. No NSApplication, window enumeration, TCC prompts or event posting.
import ApplicationServices
import Carbon
import CryptoKit
import Foundation
import Security

struct Stop: Error, CustomStringConvertible {
  let description: String
  init(_ value: String) { description = value }
}
func token(_ s: String) -> String {
  SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}

struct Session: Codable {
  let uid, consoleUID: UInt32
  let securityID: SecuritySessionId
  let boot: String
  let graphics, loginComplete, ownGUI, isConsole, remoteFlag, locked: Bool
  let displays: [String]
  let axTrustedForProbe: Bool
  static func read() throws -> Self {
    var sid: SecuritySessionId = 0
    var flags = SessionAttributeBits()
    guard SessionGetInfo(callerSecuritySession, &sid, &flags) == errSecSuccess, sid != 0,
      let gui = CGSessionCopyCurrentDictionary() as? [String: Any],
      let guiUID = gui[kCGSessionUserIDKey as String] as? NSNumber,
      let console = gui[kCGSessionOnConsoleKey as String] as? Bool,
      let complete = gui[kCGSessionLoginDoneKey as String] as? Bool
    else { throw Stop("graphical login identity unavailable") }
    var info = stat()
    var size = 0
    guard stat("/dev/console", &info) == 0,
      sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1
    else { throw Stop("console or boot unknown") }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else {
      throw Stop("boot identity unavailable")
    }
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, (1...32).contains(count) else {
      throw Stop("no GUI displays")
    }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    var read: UInt32 = 0
    guard CGGetActiveDisplayList(count, &ids, &read) == .success, read == count else {
      throw Stop("changing GUI topology")
    }
    let displays = try ids.map { id -> String in
      guard CGDisplayIsInMirrorSet(id) == 0,
        let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
      else {
        throw Stop("mirrored or unknown display")
      }
      return token(CFUUIDCreateString(nil, uuid) as String)
    }
    guard Set(displays).count == displays.count else { throw Stop("ambiguous display IDs") }
    return Self(
      uid: getuid(), consoleUID: info.st_uid, securityID: sid, boot: token(String(cString: buffer)),
      graphics: flags.contains(.sessionHasGraphicAccess), loginComplete: complete,
      ownGUI: guiUID.uint32Value == getuid(),
      isConsole: console, remoteFlag: flags.contains(.sessionIsRemote),
      locked: gui["CGSSessionScreenIsLocked"] as? Bool ?? false, displays: displays.sorted(),
      axTrustedForProbe: AXIsProcessTrusted())
  }
  var graphical: Bool { graphics && loginComplete && ownGUI && !locked }
  func blockers(relativeTo original: Self) -> [String] {
    var reasons: [String] = []
    if !original.graphical || !original.isConsole || original.uid != original.consoleUID {
      reasons.append("invalid protected console baseline")
    }
    if boot != original.boot { reasons.append("protected baseline belongs to another boot") }
    if uid == original.uid || securityID == original.securityID {
      reasons.append("same protected account or Security Session")
    }
    if consoleUID != original.consoleUID { reasons.append("physical console owner changed") }
    if !graphical { reasons.append("no unlocked GUI for caller") }
    if !Set(displays).isDisjoint(with: original.displays) {
      reasons.append("protected display UUID visible to caller")
    }
    if displays.count != 2 { reasons.append("two independent test displays not observed") }
    return reasons
  }
}

func output<T: Encodable>(_ value: T) throws {
  let enc = JSONEncoder()
  enc.outputFormatting = [.sortedKeys]
  FileHandle.standardOutput.write(try enc.encode(value) + Data([10]))
}

// Carbon exposes the registered chord, modifiers and enabled bit. It does not
// expose which Mission Control command (if any) owns one of these registrations.
struct ArrowRegistrations: Encodable {
  let left, right: Bool

  static func read() throws -> Self {
    var list: Unmanaged<CFArray>?
    guard CopySymbolicHotKeys(&list) == noErr, let rows = list?.takeRetainedValue() as? [[String: Any]]
    else { throw Stop("system shortcut registrations unavailable") }
    func registered(_ code: Int) -> Bool {
      rows.contains { row in
        guard row["kHISymbolicHotKeyCode"] as? Int == code,
          row["kHISymbolicHotKeyEnabled"] as? Bool == true,
          let modifiers = row["kHISymbolicHotKeyModifiers"] as? Int else { return false }
        return modifiers & ~Int(kEventKeyModifierFnMask) == Int(controlKey)
      }
    }
    return .init(left: registered(123), right: registered(124))
  }
}
do {
  let args = Array(CommandLine.arguments.dropFirst())
  if args == ["control-arrows"] {
    try output(ArrowRegistrations.read())
    exit(0)
  }
  let session = try Session.read()
  if args == ["baseline"],
    session.graphical && session.isConsole && session.uid == session.consoleUID
  {
    try output(session)
  } else if (args.count == 2 && ["check", "check-console"].contains(args[0])) ||
              (args.count == 3 && args[0] == "check-current-console" && UUID(uuidString: args[2]) != nil) {
    let original = try JSONDecoder().decode(
      Session.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
    let checkingCurrent = args[0] == "check-current-console"
    let checkingConsole = args[0] == "check-console" || checkingCurrent
    let failures: [String]
    if checkingConsole {
      let same = original.graphical && original.isConsole && original.uid == original.consoleUID
        && session.graphical && session.isConsole && session.uid == session.consoleUID
        && session.uid == original.uid && session.securityID == original.securityID
        && session.boot == original.boot && session.displays == original.displays
        && (checkingCurrent ? session.displays == [token(args[2].uppercased())] : session.displays.count == 2)
      failures = same ? [] : ["console differs from the frozen display selection"]
    } else { failures = session.blockers(relativeTo: original) }
    struct Result: Encodable { let caller: Session, blockers: [String], verdict: String }
    try output(
      Result(
        caller: session, blockers: failures,
        verdict: failures.isEmpty ? (checkingConsole ? "CONSOLE_SCOPE_ONLY" : "ISOLATED_GUI_CANDIDATE") : "ENVIRONMENT_BLOCKED"))
    exit(failures.isEmpty ? 0 : 3)
  } else {
    throw Stop("expected baseline in physical console, or check <protected-baseline.json>")
  }
} catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(2)
}
