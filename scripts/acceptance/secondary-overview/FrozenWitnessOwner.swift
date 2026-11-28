import Darwin
import Foundation
import Security

/// A PID started by the supervisor may have a working AX server before Launch Services publishes an application.
struct FrozenWitnessOwner {
  let pid: pid_t
  let startMicroseconds: UInt64
  let executable: URL
  let codeHash: Data

  private static func birth(_ pid: pid_t) -> UInt64? {
    var b = proc_bsdinfo()
    let size = Int32(MemoryLayout.size(ofValue:b))
    guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &b, size) == size, b.pbi_pid == UInt32(pid),
          b.pbi_uid == getuid(), b.pbi_status != UInt32(SZOMB), b.pbi_start_tvsec > 0, b.pbi_start_tvusec < 1_000_000
    else { return nil }
    return b.pbi_start_tvsec * 1_000_000 + b.pbi_start_tvusec
  }
  private static func path(_ pid: pid_t) -> URL? {
    var path = [CChar](repeating:0, count:Int(MAXPATHLEN) * 4)
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
    let bytes = path.prefix { $0 != 0 }.map(UInt8.init(bitPattern:))
    return URL(fileURLWithPath:String(decoding:bytes,as:UTF8.self)).resolvingSymlinksInPath()
  }
  private static func hash(_ code: SecStaticCode?) -> Data? {
    var raw: CFDictionary?
    guard let code, SecCodeCopySigningInformation(code,SecCSFlags(rawValue:kSecCSSigningInformation),&raw) == errSecSuccess,
          let info = raw as? [String:Any], info[kSecCodeInfoIdentifier as String] as? String == "org.nearpane.lab.NearpaneSpaceWitness",
          let hash = info[kSecCodeInfoUnique as String] as? Data, !hash.isEmpty else { return nil }
    return hash
  }
  private static func liveHash(_ pid: pid_t) -> Data? {
    var guest: SecCode?, running: SecStaticCode?
    guard SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid as String:pid] as CFDictionary,[],&guest) == errSecSuccess,
          let guest, SecCodeCheckValidity(guest,[],nil) == errSecSuccess,
          SecCodeCopyStaticCode(guest,[],&running) == errSecSuccess else { return nil }
    return hash(running)
  }
  static func enroll(_ pid: pid_t, executable: URL, before deadline: Date) -> Self? {
    let expected = executable.resolvingSymlinksInPath()
    var disk: SecStaticCode?
    guard let start = birth(pid), path(pid) == expected,
          SecStaticCodeCreateWithPath(expected as CFURL,[],&disk) == errSecSuccess, let disk,
          SecStaticCodeCheckValidity(disk,[],nil) == errSecSuccess, let diskHash = hash(disk) else { return nil }
    let pinned = Self(pid:pid,startMicroseconds:start,executable:expected,codeHash:diskHash)
    let until = min(deadline,Date(timeIntervalSinceNow:1.5))
    repeat {
      guard pinned.sameProcess else { return nil }
      if pinned.verified { return pinned }
      RunLoop.current.run(until:min(until,Date(timeIntervalSinceNow:0.04)))
    } while Date() < until
    return nil
  }
  var sameProcess: Bool { Self.birth(pid) == startMicroseconds && Self.path(pid) == executable }
  var verified: Bool { sameProcess && Self.liveHash(pid) == codeHash && sameProcess }
  var confirmedAbsent: Bool { kill(pid,0) == -1 && errno == ESRCH }
}
