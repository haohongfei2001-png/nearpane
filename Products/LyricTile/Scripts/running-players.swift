import AppKit
import Foundation

// Use the same application identity surface as production. A helper/widget inside
// Music.app is not the Music application and must not silently skip an idle check.
let playerIDs: Set<String> = ["com.apple.Music", "com.spotify.client", "com.tencent.QQMusicMac", "com.netease.163music"]
let players: [[String: Any]] = NSWorkspace.shared.runningApplications.compactMap { app in
    guard let id = app.bundleIdentifier, playerIDs.contains(id), !app.isTerminated else { return nil }
    return ["bundleID": id, "pid": app.processIdentifier]
}
let data = try JSONSerialization.data(withJSONObject: players, options: [.sortedKeys])
FileHandle.standardOutput.write(data + Data([10]))
