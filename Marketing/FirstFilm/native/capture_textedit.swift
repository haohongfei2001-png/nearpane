import AppKit
import Foundation
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let rtf = "{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Helvetica Neue;}}\\f0\\fs40 Today, a little slower.\\par\\par\\fs28 Stay with what you are doing.\\par Let the music stay close.}"
let file = out.appendingPathComponent("A-quiet-moment.rtf")
try rtf.write(to: file, atomically: true, encoding: .utf8)
let script = "tell application \"TextEdit\"\nactivate\nopen POSIX file \"\(file.path)\"\nset bounds of front window to {100, 90, 850, 650}\nend tell"
let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/bin/osascript");p.arguments=["-e",script];try p.run();p.waitUntilExit()
Thread.sleep(forTimeInterval:1)
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
if let window = windows.first(where: { ($0[kCGWindowOwnerName as String] as? String)=="TextEdit" && ($0[kCGWindowLayer as String] as? Int)==0 }), let id=window[kCGWindowNumber as String] as? Int {
 let shot=Process();shot.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture");shot.arguments=["-x","-l",String(id),out.appendingPathComponent("textedit-native-window.png").path];try shot.run();shot.waitUntilExit()
 let report:[String:Any] = ["kind":"actual TextEdit WindowServer screenshot","owner":"TextEdit","windowID":id,"captureExitCode":shot.terminationStatus,"content":"Original HOLDSNOW film text","hostScale":"Actual display backing scale; not upscaled"]
 try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("textedit-source.json"))
}
