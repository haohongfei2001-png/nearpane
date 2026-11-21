import AppKit
import Foundation
import Security

let permissionSubject = CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--permission-subject"
let check = CommandLine.arguments.count == 3 ? ["--diagnostic-space-probe":"p0-space-probe-read-only-v1","--permissions":"permissions","--permission-subject":"permissions","--draft-qualification":"draft-qualification-read-only-v1"][CommandLine.arguments[2]] : nil
let checkPermissions = check != nil
guard CommandLine.arguments.count == 2 || checkPermissions, let pid = Int32(CommandLine.arguments[1]) else { exit(2) }
func kernelHost(_ pid: pid_t) -> UInt64? {
    var info = proc_bsdinfo(), bytes = [CChar](repeating:0,count:4096)
    let size = Int32(MemoryLayout.size(ofValue:info))
    guard pid > 1, proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,size)==size, info.pbi_uid==getuid(), info.pbi_pid==UInt32(pid),
          proc_pidpath(pid,&bytes,UInt32(bytes.count))>0,
          String(decoding:bytes.prefix{$0 != 0}.map(UInt8.init(bitPattern:)),as:UTF8.self)=="/Applications/Nearpane.app/Contents/MacOS/NearpaneHost"
    else { return nil }
    return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
}
func signedHostHash(_ pid: pid_t) -> String? {
    var guest: SecCode?, requirement: SecRequirement?, disk: SecStaticCode?, fields: CFDictionary?
    let rule = "anchor apple generic and identifier \"com.holdsnow.nearpane.alpha\" and certificate leaf[subject.OU] = \"ZB9D4T66QB\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    guard SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess, let requirement,
          SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: pid] as CFDictionary, [], &guest) == errSecSuccess, let guest,
          SecCodeCheckValidity(guest, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess,
          SecCodeCopyStaticCode(guest, [], &disk) == errSecSuccess, let disk,
          SecCodeCopySigningInformation(disk, .init(rawValue: kSecCSSigningInformation), &fields) == errSecSuccess,
          let digest = (fields as? [String:Any])?[kSecCodeInfoUnique as String] as? Data, !digest.isEmpty else { return nil }
    return digest.map { String(format: "%02x", $0) }.joined()
}
let diagnosticProbe = check == "p0-space-probe-read-only-v1"
let app = NSRunningApplication(processIdentifier:pid)
let birth = diagnosticProbe || permissionSubject ? kernelHost(pid) : nil
let image = permissionSubject ? signedHostHash(pid) : nil
if permissionSubject && (image == nil || birth == nil) { exit(2) }
if diagnosticProbe {
    guard birth != nil else { exit(2) }
} else {
    guard app?.bundleURL?.standardizedFileURL.path == "/Applications/Nearpane.app",
          app?.bundleIdentifier == "com.holdsnow.nearpane.alpha" else { exit(2) }
}
let center = DistributedNotificationCenter.default()
let nonce = UUID().uuidString
var received: [String: Any]?
let token = center.addObserver(forName: .init("com.holdsnow.nearpane.preview-metrics.reply"),
                               object: nonce, queue: .main) { notice in
    guard let fields = notice.userInfo, fields["pid"] as? Int32 == pid else { return }
    if checkPermissions {
        guard fields["checked"] as? String == check else { return }
        received = ["pid": Int(pid)]
        return
    }
    let names = ["captureRequests", "capturesInFlight", "cacheEntries", "chargedPixelBytes", "activeStreams",
                 "visibleDisplays", "gallerySessions"]
    var output: [String: Any] = ["pid": Int(pid)]
    for name in names {
        guard let number = fields[name] as? NSNumber, number.intValue >= 0 else { return }
        output[name] = number.intValue
    }
    for name in ["windowManagementBusy", "surfaceHidden", "visibilityRevision", "stageManagerOwnsDispatch",
                 "windowDispatchEligible", "overviewShortcutRegistered", "missionControlPresented", "deliveredFrames"] {
        if let value = fields[name] as? NSNumber { output[name] = value.intValue }
    }
    if let reason = fields["missionControlObservation"] as? String, reason.utf8.count <= 64,
       reason.range(of: "^[A-Za-z]+$", options: .regularExpression) != nil {
        output["missionControlObservation"] = reason
    }
    received = output
}
var request = ["nonce": nonce]
if let check { request["check"] = check }
center.postNotificationName(.init("com.holdsnow.nearpane.preview-metrics.request"), object: String(pid),
                            userInfo: request, deliverImmediately: true)
let until = ProcessInfo.processInfo.systemUptime + ((check == "draft-qualification-read-only-v1" || check == "p0-space-probe-read-only-v1") ? 6 : 1.25)
while received == nil, ProcessInfo.processInfo.systemUptime < until { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03)) }
center.removeObserver(token)
guard let received, diagnosticProbe ? (kernelHost(pid) == birth) : (app?.isTerminated == false) else { exit(3) }
if permissionSubject {
    guard let image, let birth, kernelHost(pid) == birth, signedHostHash(pid) == image else { exit(3) }
    let result: [String:Any] = ["pid": Int(pid), "birth": birth, "cdhash": image, "nonce": nonce]
    print(String(decoding:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),as:UTF8.self))
} else if checkPermissions {
    print(nonce)
} else {
    print(String(decoding:try JSONSerialization.data(withJSONObject:received),as:UTF8.self))
}
