// A manually opened, one-use lab entry. No window, Dock activation, or permission request.
import AppKit
import ApplicationServices
import CryptoKit

struct Plan: Decodable {
    let directory, repository, display, python: String
    let helpersSHA256, witnessSHA256: String
    let scripts: [String: String]
    let secondarySource: String?
    let displayFingerprints: [String]?

    var route: [String] {
        if let secondarySource { return ["--allow-primary-overview", "--source", secondarySource] }
        return ["--current-display", "--provision-current", "--source", "rightmost-current"]
    }

    func verifySecondaryScreens() throws {
        guard let secondarySource else { return }
        try checked(UInt64(secondarySource).map { $0 > 0 && String($0) == secondarySource } == true,
                    "未指定有效的副屏普通桌面。")
        let screens = NSScreen.screens
        try checked(screens.count == 2, "副屏验收需要两块独立显示器。")
        var fingerprints = Set<String>()
        var expectedSecondary = false
        for screen in screens {
            guard let id = (screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.uint32Value,
                  CGDisplayIsInMirrorSet(id) == 0,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
            else { throw Refusal("无法确认两块显示器的独立身份。") }
            let identity = (CFUUIDCreateString(nil, uuid) as String).uppercased()
            fingerprints.insert(SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined())
            if id != CGMainDisplayID() && identity == display { expectedSecondary = true }
        }
        try checked(expectedSecondary && fingerprints.count == 2 && fingerprints == Set(displayFingerprints ?? []),
                    "显示器身份或主副屏归属已改变。")
    }
}

struct Refusal: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
    init(_ reason: String) { self.reason = reason }
}

func checked(_ ok: Bool, _ message: String) throws {
    if !ok { throw Refusal(message) }
}

struct Delivery {
    let plan: Plan
    let folder: URL
    let repository: URL

    init() throws {
        guard let config = Bundle.main.url(forResource: "trial", withExtension: "json")
        else { throw Refusal("缺少签封配置。") }
        plan = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: config))
        folder = URL(fileURLWithPath:plan.directory).standardizedFileURL
        repository = URL(fileURLWithPath: plan.repository)
        let expectedApp = folder.appendingPathComponent(Bundle.main.bundleURL.lastPathComponent)
        try checked(expectedApp.resolvingSymlinksInPath().path == Bundle.main.bundleURL.resolvingSymlinksInPath().path, "请从原交付目录打开验收工具。")
    }

    func verify() throws {
        func fingerprint(_ file: URL) throws -> String {
            SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        }
        for (relative, expected) in plan.scripts {
            try checked(try fingerprint(repository.appendingPathComponent(relative)) == expected, "验收脚本有更新，请重新制作验收入口。")
        }
        try checked(try fingerprint(folder.appendingPathComponent("tools/overview/SHA256SUMS")) == plan.helpersSHA256
                    && fingerprint(folder.appendingPathComponent("tools/witness/SHA256SUMS")) == plan.witnessSHA256,
                    "冻结工具清单已改变。")
    }

    func status(_ message: String) throws {
        try (message + "\n").write(to: folder.appendingPathComponent("验收结果.txt"), atomically: true, encoding: .utf8)
    }

    func start(at begin: Date) throws {
        // O_EXCL persists across Finder reopen, app crash, and a second copy of the process.
        let claim = folder.appendingPathComponent("started.json")
        let fd = open(claim.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        if fd < 0 && errno == EEXIST { return }
        try checked(fd >= 0, "无法保存本次启动凭据。")
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let clock = ISO8601DateFormatter()
        let finish = begin.addingTimeInterval(600)
        try handle.write(contentsOf: JSONEncoder().encode(["started":clock.string(from:begin), "ends":clock.string(from:finish)]))
        try handle.synchronize()
        try handle.close()
        do {
            try verify()
            try plan.verifySecondaryScreens()
            try status("正在验收，最晚结束时间为 " + clock.string(from:finish) + "。结果将写在此处。")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: plan.python)
            p.currentDirectoryURL = repository
            p.arguments = ["-I", "-B", repository.appendingPathComponent("scripts/acceptance/secondary-overview/run-route.py").path,
                           "--check-overview-first"] + plan.route +
                          ["--display", plan.display, "--kit", folder.appendingPathComponent("tools/overview").path,
                           "--witness", folder.appendingPathComponent("tools/witness").path, "--witness-manifest", plan.witnessSHA256,
                           "--starts", clock.string(from:begin), "--ends", clock.string(from:finish)]
            p.standardInput = FileHandle.nullDevice
            let log = folder.appendingPathComponent("supervisor.log")
            try checked(FileManager.default.createFile(atPath: log.path, contents: nil, attributes:[.posixPermissions:0o600]),
                        "无法保存监督程序的输出。")
            let output = try FileHandle(forWritingTo: log)
            p.standardOutput = output
            p.standardError = output
            try p.run()
            p.waitUntilExit()
            try output.close()
            let lines = try String(contentsOf: log, encoding:.utf8).split(separator:"\n")
            let runs = repository.appendingPathComponent("build/verification/secondary-route-followup")
            guard let first = lines.first else { throw Refusal("监督程序未返回本次收据目录。请查看 supervisor.log。") }
            let trial = URL(fileURLWithPath:String(first)).standardizedFileURL
            try checked(trial.deletingLastPathComponent().path == runs.path && UUID(uuidString:trial.lastPathComponent) != nil,
                        "收据目录无法确认。请查看 supervisor.log。")
            let complete = trial.appendingPathComponent("complete.json")
            let stopped = trial.appendingPathComponent("stopped.json")
            if p.terminationReason == .exit, p.terminationStatus == 0,
               let receipt = try? JSONSerialization.jsonObject(with: Data(contentsOf: complete)) as? [String:Any],
               receipt["roundTrips"] as? Int == 3, receipt["createdAndRemoved"] as? Bool == true {
                try status("通过。三轮原生桌面往返已核实，临时桌面已清理。\n收据：" + trial.path)
            } else {
                let receipt = try? JSONSerialization.jsonObject(with: Data(contentsOf: stopped)) as? [String:Any]
                let reason = receipt?["reason"] as? String ?? "结果尚未确认，请检查 supervisor.log。"
                try status("验收已停止。\n" + reason + "\n收据：" + trial.path)
            }
        } catch { try status("验收已停止。\n" + error.localizedDescription) }
    }
}

@main final class FinderTrial: NSObject, NSApplicationDelegate {
    var accepted = false

    // Read only the owner of the window at the last hardware click.
    static func clickedFinder(at point: NSPoint, finder: NSRunningApplication) -> Bool {
        guard finder.bundleIdentifier == "com.apple.finder",
              finder.executableURL?.resolvingSymlinksInPath().path == "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",
              !finder.isTerminated,
              let window = UInt32(exactly: NSWindow.windowNumber(at:point, belowWindowWithWindowNumber:0)), window > 0,
              let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, window) as? [[String:Any]],
              rows.count == 1, rows[0][kCGWindowNumber as String] as? UInt32 == window,
              rows[0][kCGWindowOwnerPID as String] as? Int32 == finder.processIdentifier,
              NSEvent.mouseLocation == point,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == finder.processIdentifier
        else { return false }
        return true
    }
    func applicationDidFinishLaunching(_ note: Notification) {
        defer { NSApp.terminate(nil) }
        do {
            let delivery = try Delivery()
            if FileManager.default.fileExists(atPath:delivery.folder.appendingPathComponent("started.json").path) { return }
            guard note.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool == true,
                  let finder = NSWorkspace.shared.frontmostApplication,
                  finder.bundleIdentifier == "com.apple.finder",
                  !accepted, CommandLine.arguments.count == 1 else {
                try delivery.status("尚未启动验收。请在 Finder 中直接双击本目录的验收应用。")
                return
            }
            let lastUp = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType:.leftMouseUp)
            let lastDown = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType:.leftMouseDown)
            let point = NSEvent.mouseLocation
            guard lastUp.isFinite, lastDown.isFinite, lastUp >= 0, lastUp <= lastDown, lastDown <= 4,
                  [.mouseMoved, .leftMouseDragged, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel].allSatisfy({
                    CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType:$0) >= lastUp
                  }), NSEvent.pressedMouseButtons == 0, Self.clickedFinder(at:point, finder:finder) else {
                try delivery.status("尚未启动验收。没有检测到此次 Finder 打开的近期鼠标输入。")
                return
            }
            accepted = true
            try delivery.start(at: Date(timeIntervalSinceNow: -lastUp))
        } catch { fputs(error.localizedDescription + "\n",stderr) }
    }

    static func main() {
        if CommandLine.arguments.dropFirst().elementsEqual(["--verify-only"]) {
            do { try Delivery().verify(); print("Frozen manifests and supervisor scripts verified.") }
            catch { fputs(error.localizedDescription + "\n",stderr); exit(2) }
            return
        }
        let delegate = FinderTrial()
        let app = NSApplication.shared
        guard app.activationPolicy() == .prohibited || app.setActivationPolicy(.prohibited) else { return }
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
