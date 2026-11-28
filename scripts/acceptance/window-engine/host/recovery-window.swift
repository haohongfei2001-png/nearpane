// Read only the process generation and WindowServer rectangle named in an existing recovery journal.
import AppKit
import Darwin

let arguments = CommandLine.arguments
guard arguments.count == 4, let pid = Int32(arguments[1]), pid > 1,
      let expectedBirth = UInt64(arguments[2]), expectedBirth > 0,
      let window = UInt32(arguments[3]), window > 0 else { exit(2) }

func birth() -> UInt64? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout.size(ofValue: info))
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
          info.pbi_pid == UInt32(pid), info.pbi_uid == getuid() else { return nil }
    return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
}

var samples = [[String: Any]]()
for index in 0..<2 {
    if index > 0 { Thread.sleep(forTimeInterval: 0.18) }
    let before = birth()
    var sample: [String: Any] = ["uptime": ProcessInfo.processInfo.systemUptime]
    if before == expectedBirth {
        let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, window) as? [[String: Any]]
        let exact = rows?.filter {
            ($0[kCGWindowOwnerPID as String] as? Int32) == pid &&
            ($0[kCGWindowNumber as String] as? UInt32) == window
        }
        sample["exactWindowCount"] = exact?.count
        if exact?.count == 1, let row = exact?.first {
            let app = NSRunningApplication(processIdentifier: pid)
            sample["regularForeground"] = row[kCGWindowLayer as String] as? Int == 0 &&
                row[kCGWindowIsOnscreen as String] as? Bool == true && app?.activationPolicy == .regular &&
                app?.isHidden == false && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        }
        if exact?.count == 1, let raw = exact?.first?[kCGWindowBounds as String] as? [String: NSNumber],
           let x = raw["X"], let y = raw["Y"], let width = raw["Width"], let height = raw["Height"] {
            sample["windowServerFrame"] = ["x": x, "y": y, "width": width, "height": height]
        }
    }
    sample["processBirthMatches"] = before == expectedBirth && birth() == expectedBirth
    samples.append(sample)
}
let data = try JSONSerialization.data(withJSONObject: samples, options: [.sortedKeys])
try FileHandle.standardOutput.write(contentsOf: data)
