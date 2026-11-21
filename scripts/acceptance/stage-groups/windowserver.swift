import AppKit
import CReadOnlySpaces
import NearpaneCore

private enum FixtureError: String, Error { case registration, display, owner, missingWindow, invalidGroup, staleBinding }
private struct Owner: Codable {
    let identifier: String, pid: Int32, birth: UInt64, display: UUID, numbers: [UInt32], onActiveSpace: Bool
}

private func birth(_ pid: Int32) throws -> UInt64 {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout.size(ofValue: info))
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_pid == UInt32(pid),
          info.pbi_uid == getuid() else { throw FixtureError.owner }
    return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
}

@MainActor private func screenIdentity(_ screen: NSScreen) throws -> (UUID, CGDirectDisplayID) {
    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
          let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
          let id = UUID(uuidString: CFUUIDCreateString(nil, uuid) as String) else { throw FixtureError.display }
    return (id, number.uint32Value)
}

@MainActor private final class OwnerDelegate: NSObject, NSApplicationDelegate {
    let root: URL, name: String
    private var windows = [NSWindow]()
    init(root: URL, name: String) { self.root = root; self.name = name }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do {
                let expectedBundle = "net.example.nearpane.stage-group-" + name
                guard NSRunningApplication.current.bundleIdentifier == expectedBundle,
                      NSRunningApplication.current.bundleURL?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL,
                      NSApp.activationPolicy() == .regular, let screen = NSScreen.main else { throw FixtureError.registration }
                let (id, _) = try screenIdentity(screen)
                for index in 0..<(name == "a" ? 2 : 1) {
                    let x = screen.visibleFrame.minX + (name == "b" ? 280 : CGFloat(20 + index * 100))
                    let rect = CGRect(x: x, y: screen.visibleFrame.midY, width: 140, height: 100)
                    let window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                          backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.title = "Stage group fixture"
                    window.backgroundColor = index == 1 ? .yellow : (name == "a" ? .red : .blue)
                    windows.append(window)
                    window.orderFront(nil)
                }
                try await Task.sleep(for: .milliseconds(250))
                let owner = Owner(identifier: expectedBundle, pid: getpid(), birth: try birth(getpid()), display: id,
                                  numbers: windows.map { UInt32($0.windowNumber) },
                                  onActiveSpace: windows.allSatisfy { $0.isVisible && $0.isOnActiveSpace && $0.screen == screen })
                try JSONEncoder().encode(owner).write(to: root.appendingPathComponent(name + ".json"), options: .atomic)
                let deadline = ContinuousClock.now + .seconds(40)
                while ContinuousClock.now < deadline && !FileManager.default.fileExists(atPath: root.appendingPathComponent("stop").path) {
                    try await Task.sleep(for: .milliseconds(100))
                }
            } catch { fputs("Fixture owner failed: \(error)\n", stderr) }
            windows.forEach { $0.close() }
            NSApp.terminate(nil)
        }
    }
}

@MainActor private func check(_ phase: String, root: URL) throws {
    let owners = try ["a", "b"].map { try JSONDecoder().decode(Owner.self, from: Data(contentsOf: root.appendingPathComponent($0 + ".json"))) }
    guard let screen = NSScreen.main, let first = owners.first else { throw FixtureError.display }
    let (id, number) = try screenIdentity(screen)
    let screenBounds = CGDisplayBounds(number)
    let screenFrame = screen.frame
    let usable = screen.visibleFrame
    let work = SurfaceRect(x: usable.minX - screenFrame.minX, y: screenFrame.maxY - usable.maxY,
                           width: usable.width, height: usable.height)
    guard owners.allSatisfy({ $0.display == id && $0.onActiveSpace }), Set(owners.map(\.pid)).count == 2,
          let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { throw FixtureError.display }
    let nativeReadable = NPProbeReadOnlyCatalog() == 1
    var spaces = [[UInt64]]()
    var windows = [StageGroupWindow]()
    for owner in owners {
        guard try birth(owner.pid) == owner.birth,
              NSRunningApplication(processIdentifier: owner.pid)?.bundleIdentifier == owner.identifier else { throw FixtureError.owner }
        for n in owner.numbers {
            let rows = all.filter { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == n }
            guard rows.count == 1, let row = rows.first, (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == owner.pid,
                  row[kCGWindowLayer as String] as? Int == 0, let raw = row[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: raw), screenBounds.contains(frame) else { throw FixtureError.missingWindow }
            if nativeReadable, let list = NPReadWindowSpaces(n) as? [NSNumber] { spaces.append(list.map(\.uint64Value)) }
            let local = SurfaceRect(x: frame.minX - screenBounds.minX, y: frame.minY - screenBounds.minY,
                                    width: frame.width, height: frame.height)
            guard let layout = StageGroupWindow.relativeFrame(local, in: work) else { throw FixtureError.display }
            windows.append(.init(display: id, identity: .init(pid: owner.pid, birth: owner.birth, number: n),
                                 lifetime: UUID(), layout: layout))
        }
    }
    guard windows.count == 3, first.numbers.count == 2 else { throw FixtureError.missingWindow }
    let profile = root.appendingPathComponent("profile")
    let store = StageGroupStore(profile: profile)
    let stateFile = root.appendingPathComponent("expected-directory.json")
    let reopening = phase == "reopen"
    if reopening {
        let original = try JSONDecoder().decode(StageGroupDirectory.self, from: Data(contentsOf: stateFile))
        guard store.directory == original else { throw FixtureError.invalidGroup }
        try store.observe(windows)
        guard store.projectedGroups(on: id, among: windows).isEmpty else { throw FixtureError.staleBinding }
        for w in windows { try store.rebind(w) }
    } else {
        try store.observe(windows)
        try store.join(windows[2], to: windows[0])
        try JSONEncoder().encode(store.directory).write(to: stateFile, options: .withoutOverwriting)
    }
    let projected = store.projectedGroups(on: id, among: windows)
    guard projected.count == 2, projected[0].members.map(\.windowHint) == [windows[0].identity, windows[2].identity],
          projected[1].members.map(\.windowHint) == [windows[1].identity], store.directory.displays.first?.activeGroup == nil,
          projected.flatMap(\.members).allSatisfy({ m in m.layout == windows.first { $0.identity == m.windowHint }?.layout })
    else { throw FixtureError.invalidGroup }
    let sameSpace = spaces.count == 3 && spaces.allSatisfy { $0.count == 1 && $0 == spaces[0] }
    let nativeStatus = spaces.count == 3 ? (sameSpace ? "PASS" : "FAIL") : "UNKNOWN"
    let result: [String: Any] = ["status": "PASS", "inspectorPID": getpid(), "physicalDisplayUUID": id.uuidString,
        "separateOwners": owners.count, "onScreenWindows": windows.count, "checkedNativeMembership": nativeStatus,
        "nativeMembership": spaces, "groupSizes": projected.map { $0.members.count }, "groupIDs": projected.map { $0.id.uuidString },
        "noActiveGroupInferred": true, "layoutCheckedAgainstWindowServer": true, "oldBindingsIneligible": reopening,
        "axTrusted": AXIsProcessTrusted(), "systemStageManagerOwnsDispatch": StageManagerPreference.ownsWindowDispatch]
    try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: root.appendingPathComponent(phase + ".json"), options: .withoutOverwriting)
    if nativeStatus == "FAIL" { throw FixtureError.invalidGroup }
}

@main private struct Fixture {
    @MainActor static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 2, ["a", "b", "record", "reopen"].contains(args[0]),
              ProcessInfo.processInfo.environment["RUNNER_ENVIRONMENT"] == "github-hosted" else { exit(64) }
        let root = URL(fileURLWithPath: args[1], isDirectory: true)
        if args[0] == "record" || args[0] == "reopen" {
            do { try check(args[0], root: root) }
            catch { fputs("Fixture check \(args[0]) failed: \(error)\n", stderr); exit(1) }
            return
        }
        let app = NSApplication.shared, delegate = OwnerDelegate(root: root, name: args[0])
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
