import AppKit
import Foundation

let check = CommandLine.arguments.count == 3 ? ["--permissions":"permissions","--draft-qualification":"draft-qualification-read-only-v1"][CommandLine.arguments[2]] : nil
let checkPermissions = check != nil
guard CommandLine.arguments.count == 2 || checkPermissions, let pid = Int32(CommandLine.arguments[1]),
      let app = NSRunningApplication(processIdentifier: pid),
      app.bundleURL?.standardizedFileURL.path == "/Applications/Nearpane.app",
      app.bundleIdentifier == "com.holdsnow.nearpane.alpha" else { exit(2) }
let center = DistributedNotificationCenter.default()
let nonce = UUID().uuidString
var received: [String: Int]?
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
    var output = ["pid": Int(pid)]
    for name in names {
        guard let number = fields[name] as? NSNumber, number.intValue >= 0 else { return }
        output[name] = number.intValue
    }
    for name in ["windowManagementBusy", "surfaceHidden", "visibilityRevision", "stageManagerOwnsDispatch", "deliveredFrames"] {
        if let value = fields[name] as? NSNumber { output[name] = value.intValue }
    }
    received = output
}
var request = ["nonce": nonce]
if let check { request["check"] = check }
center.postNotificationName(.init("com.holdsnow.nearpane.preview-metrics.request"), object: String(pid),
                            userInfo: request, deliverImmediately: true)
let until = ProcessInfo.processInfo.systemUptime + (check == "draft-qualification-read-only-v1" ? 5 : 1.25)
while received == nil, ProcessInfo.processInfo.systemUptime < until { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03)) }
center.removeObserver(token)
guard let received, !app.isTerminated else { exit(3) }
if checkPermissions {
    print(nonce)
} else {
    print(String(decoding:try JSONEncoder().encode(received),as:UTF8.self))
}
