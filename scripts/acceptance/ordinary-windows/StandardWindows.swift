// Standalone sample app. Only the acceptance runner reads stdout or owns its stdin.
// Its NSWindows expose standard AppKit accessibility, with no custom attributes.
import AppKit
import Darwin

func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { exit(2) }
    FileHandle.standardOutput.write(data + Data([10]))
}
func bounds(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height] }
// LaunchServices on this build can omit arguments of a GUI-only application.
// The runner places only its disposable pipe path beside the separately signed app.
let ticket = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("sample-pipes")
guard let pipe = try? String(contentsOf:ticket, encoding:.utf8),
      pipe.hasPrefix("/private/tmp/np-window-pipes-"),
      pipe.split(separator:"/").count == 3 else { exit(2) }
let io = URL(fileURLWithPath:pipe)
var st = stat()
guard lstat(io.path,&st) == 0, st.st_uid == getuid(), st.st_mode & 0o777 == 0o700,
      st.st_mode & S_IFMT == S_IFDIR else { exit(2) }
for (name, target, flags) in [("requests", STDIN_FILENO,O_RDONLY),("reports",STDOUT_FILENO,O_WRONLY)] {
    let path = io.appendingPathComponent(name).path
    guard lstat(path,&st) == 0, st.st_uid == getuid(), st.st_mode & S_IFMT == S_IFIFO else { exit(2) }
    let fd=open(path,flags | O_NOFOLLOW)
    guard fd>=0, dup2(fd,target)>=0 else { exit(2) }; if fd != target { close(fd) }
}
let app = NSApplication.shared
let regular = Bundle.main.bundleIdentifier == "net.example.standard-documents"
guard regular,
      let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
      front != getpid(), !app.isActive, NSScreen.screens.count == 2,
      let secondary = NSScreen.screens.last, let primary = NSScreen.screens.first,
      !secondary.frame.intersects(primary.frame) else { emit(["refused":"isolated secondary required"]); exit(2) }
let safeSecondaryFrame = secondary.frame
let primaryTop = primary.frame.maxY
let policy: NSApplication.ActivationPolicy = .regular
guard app.activationPolicy() == policy else { emit(["refused":"activation policy"]); exit(2) }
NSWindow.allowsAutomaticWindowTabbing = false
var windows = [Int: NSWindow]()
var focusEvents = 0
var history = [UInt32]()
@MainActor func finish(_ reason: String, _ status: Int32) -> Never {
    // Disconnect the sample process once. WindowServer removes its windows as a group.
    emit(["exit":reason,"numbers":history,"focusEvents":focusEvents]); exit(status)
}
@MainActor func safe() -> Bool {
    NSScreen.screens.count == 2 && safeSecondaryFrame == NSScreen.screens.last?.frame &&
    NSWorkspace.shared.frontmostApplication?.processIdentifier == front && !app.isActive &&
    windows.values.allSatisfy { !$0.isKeyWindow && !$0.isMainWindow && safeSecondaryFrame.contains($0.frame) } &&
    focusEvents == 0
}
@MainActor func add(_ n: Int) {
    let visible = secondary.visibleFrame
    let rect = CGRect(x: visible.minX + 95, y: visible.minY + 110 + CGFloat(n - 1) * 205, width: 240, height: 152)
    guard safe(), visible.contains(rect), n > 0, n <= 4, windows[n] == nil else { finish("unsafe window geometry", 2) }
    let w = NSWindow(contentRect: rect, styleMask: [.titled,.closable,.miniaturizable,.resizable],
                     backing:.buffered, defer:true, screen:secondary)
    w.isReleasedWhenClosed = false
    w.isRestorable = false
    w.ignoresMouseEvents = true
    w.title = "Sample \(n)"
    w.collectionBehavior = n == 1 ? [.primary] : [.auxiliary]
    w.contentView = NSTextField(labelWithString:"Blank sample \(n)")
    w.setFrame(rect, display:false)
    guard safe(), secondary.frame.contains(w.frame) else { finish("before display",2) }
    w.orderFrontRegardless()
    windows[n] = w
    history.append(UInt32(w.windowNumber))
}
@MainActor func report() {
    let rows:[[String:Any]] = windows.sorted { $0.key < $1.key }.map { n, w in
        let f = w.frame
        return ["index":n,"number":w.windowNumber,"frame":[f.minX,primaryTop-f.maxY,f.width,f.height],
                "key":w.isKeyWindow,"main":w.isMainWindow,"minSize":[w.minSize.width,w.minSize.height]]
    }
    emit(["pid":getpid(),"policy":"regular","windows":rows,"front":front,"focusEvents":focusEvents])
}
let _observers = [NSWindow.didBecomeKeyNotification,NSWindow.didBecomeMainNotification,
                  NSApplication.didBecomeActiveNotification].map { note in
    NotificationCenter.default.addObserver(forName:note,object:nil,queue:.main) { _ in focusEvents += 1 }
}
let started = ProcessInfo.processInfo.systemUptime
let parent = getppid()
let timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { _ in
    MainActor.assumeIsolated {
        guard safe(), getppid() == parent, ProcessInfo.processInfo.systemUptime-started < 240 else { finish("deadline, focus or display changed",2) }
    }
}
DispatchQueue.global().async {
    while let line = readLine() {
        DispatchQueue.main.sync {
            guard safe() else { finish("scope lost",2) }
            let fields = line.split(separator:" ")
            switch fields.first {
            case "add" where fields.count == 2: add(Int(fields[1]) ?? 0)
            case "close" where fields.count == 2:
                if let n = Int(fields[1]), let w = windows.removeValue(forKey:n) { w.close() }
            case "edit" where fields.count == 2:
                // The tested application simulates its own external layout edit. No AX request.
                guard let n = Int(fields[1]), let w = windows[n] else { finish("wrong edit subject",2) }
                let r = CGRect(x:secondary.visibleFrame.midX-110,y:secondary.visibleFrame.midY-85,width:220,height:170)
                guard secondary.visibleFrame.contains(r) else { finish("unsafe edit",2) }
                w.setFrame(r,display:true)
            case "read": break
            case "quit": finish("requested",0)
            default: finish("bad command",2)
            }
            report()
        }
    }
    DispatchQueue.main.async { finish("runner disconnected",0) }
}
emit(["ready":getpid(),"front":front])
app.run()
