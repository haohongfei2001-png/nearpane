// Test the custom Nearpane chord once during an enrolled installed-host handoff. No key events.
import AppKit
import Carbon.HIToolbox
import Foundation

let args = CommandLine.arguments
guard args.count == 2, let pid = Int32(args[1]), pid > 1,
      let host = NSRunningApplication(processIdentifier: pid),
      host.bundleIdentifier == "com.holdsnow.nearpane.alpha",
      host.executableURL?.path == "/Applications/Nearpane.app/Contents/MacOS/NearpaneHost" else { exit(2) }
NSApplication.shared.setActivationPolicy(.prohibited)
let modifiers = UInt32(controlKey | optionKey | cmdKey)
var table: Unmanaged<CFArray>?
var data: [String: Any] = ["pid": pid, "keyEventsSent": 0, "state": "unknown"]
if CopySymbolicHotKeys(&table) == noErr, let rows = table?.takeRetainedValue() as? [[String: Any]] {
    let reserved = rows.contains { row in
        guard row["kHISymbolicHotKeyEnabled"] as? Bool == true,
              (row["kHISymbolicHotKeyCode"] as? NSNumber)?.intValue == kVK_UpArrow,
              let flags = (row["kHISymbolicHotKeyModifiers"] as? NSNumber)?.uint32Value else { return false }
        return flags & ~UInt32(kEventKeyModifierFnMask) == modifiers
    }
    if reserved { data["state"] = "systemReserved" }
    else {
        var key: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(kVK_UpArrow), modifiers, EventHotKeyID(signature: 0x4E705450, id: 1),
                                        GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &key)
        data["registration"] = status
        if status == noErr, let key {
            let release = UnregisterEventHotKey(key)
            data["release"] = release
            if release == noErr { data["state"] = "available" }
        } else if status == eventHotKeyExistsErr { data["state"] = "occupied" }
    }
}
guard !host.isTerminated else { exit(2) }
print(String(decoding: try JSONSerialization.data(withJSONObject: data), as: UTF8.self))
