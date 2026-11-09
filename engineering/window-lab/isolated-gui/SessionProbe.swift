// Read-only. No NSApplication, window enumeration, TCC prompts or event posting.
import ApplicationServices
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
do {
  let args = Array(CommandLine.arguments.dropFirst())
  let session = try Session.read()
  if args == ["baseline"],
    session.graphical && session.isConsole && session.uid == session.consoleUID
  {
    try output(session)
  } else if args.count == 2 && args[0] == "check" {
    let original = try JSONDecoder().decode(
      Session.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
    let failures = session.blockers(relativeTo: original)
    struct Result: Encodable { let caller: Session, blockers: [String], verdict: String }
    try output(
      Result(
        caller: session, blockers: failures,
        verdict: failures.isEmpty ? "ISOLATED_GUI_CANDIDATE" : "ENVIRONMENT_BLOCKED"))
    exit(failures.isEmpty ? 0 : 3)
  } else {
    throw Stop("expected baseline in physical console, or check <protected-baseline.json>")
  }
} catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(2)
}
