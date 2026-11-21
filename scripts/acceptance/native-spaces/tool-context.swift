// Installed product identity, isolated profile ownership and native observations shared by tool trials.
import AppKit
import ApplicationServices
import Vision
import ScreenCaptureKit

struct ToolRefusal: LocalizedError {
    var errorDescription: String?
    init(_ reason: String) { errorDescription = reason }
}

@MainActor
enum ToolUI {
    static func value(_ node: AXUIElement, _ key: String) -> CFTypeRef? {
        var val: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, key as CFString, &val) == .success else { return nil }
        return val
    }

    static func frame(_ node: AXUIElement) -> CGRect? {
        guard let origin = value(node,kAXPositionAttribute), CFGetTypeID(origin) == AXValueGetTypeID(),
              let size = value(node,kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(origin as! AXValue,.cgPoint,&p), AXValueGetValue(size as! AXValue,.cgSize,&s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    static func nodes(_ host: NSRunningApplication) -> [AXUIElement] {
        let root = AXUIElementCreateApplication(host.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.35)
        var queue = value(root,kAXWindowsAttribute) as? [AXUIElement] ?? []
        var read: [AXUIElement] = []
        while let node = queue.popLast(), read.count < 1800 {
            read.append(node)
            if let kids = value(node,kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf:kids) }
        }
        return read
    }

    static func labels(_ item: AXUIElement) -> [String] {
        [kAXTitleAttribute,kAXDescriptionAttribute,kAXValueAttribute].compactMap { value(item,$0) as? String }
    }

    static func press(_ host: NSRunningApplication, label: String) -> Bool {
        for node in nodes(host) where labels(node).contains(label) {
            if AXUIElementPerformAction(node,kAXPressAction as CFString) == .success { return true }
        }
        return false
    }

    static func press(_ host: NSRunningApplication, identifier: String) -> Bool {
        guard let item = nodes(host).first(where: { value($0,kAXIdentifierAttribute) as? String == identifier }) else { return false }
        return AXUIElementPerformAction(item,kAXPressAction as CFString) == .success
    }

    static func openSettings(_ host: NSRunningApplication) async throws {
        func containsSettings() -> Bool {
            nodes(host).contains { value($0,kAXIdentifierAttribute) as? String == "settings-nav-modules" }
        }
        if containsSettings() { return }
        let app = AXUIElementCreateApplication(host.processIdentifier)
        guard let bar = value(app,"AXExtrasMenuBar"), CFGetTypeID(bar) == AXUIElementGetTypeID(),
              let item = (value(bar as! AXUIElement,kAXChildrenAttribute) as? [AXUIElement])?.first else {
            throw ToolRefusal("Nearpane's own status menu is unavailable")
        }
        AXUIElementSetMessagingTimeout(item,0.35)
        _ = AXUIElementPerformAction(item,kAXPressAction as CFString)
        for _ in 0..<20 {
            if let menu = (value(item,kAXChildrenAttribute) as? [AXUIElement])?.first(where: { value($0,kAXRoleAttribute) as? String == "AXMenu" }),
               let open = (value(menu,kAXChildrenAttribute) as? [AXUIElement])?.first(where: { value($0,kAXTitleAttribute) as? String == "打开 Nearpane" }),
               AXUIElementPerformAction(open,kAXPressAction as CFString) == .success {
                for _ in 0..<22 {
                    if containsSettings() { return }
                    await pause(100)
                }
                break
            }
            await pause(75)
        }
        _ = AXUIElementPerformAction(item,kAXCancelAction as CFString)
        throw ToolRefusal("The installed status menu did not expose the settings window")
    }

    static func windows(_ pid: pid_t) -> [(id: CGWindowID, level: Int, bounds: CGRect)] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
        return list.compactMap { w in
            guard w[kCGWindowOwnerPID as String] as? Int32 == pid,
                  let id = w[kCGWindowNumber as String] as? UInt32,
                  let l = w[kCGWindowLayer as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation:b) else { return nil }
            return (id,l,r)
        }
    }

    static func run(_ path: String, _ args: [String]) throws -> String {
        let child = Process(), stdout = Pipe()
        child.executableURL = URL(fileURLWithPath:path); child.arguments = args
        child.standardOutput = stdout; child.standardError = FileHandle.nullDevice
        try child.run()
        let bytes = stdout.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        guard child.terminationStatus == 0 else { throw ToolRefusal("System observation failed: " + child.executableURL!.lastPathComponent) }
        return String(decoding:bytes,as:UTF8.self)
    }

    static func ownedImage(_ number: CGWindowID, pid: pid_t) async throws -> CGImage {
        guard number != 0, windows(pid).contains(where: { $0.id == number }) else {
            throw ToolRefusal("Owned window no longer exists")
        }
        let content=try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:true)
        guard let source=content.windows.first(where:{ $0.windowID==number && $0.owningApplication?.processID==pid }) else {
            throw ToolRefusal("The verified source is no longer available for a window-only capture")
        }
        let filter=SCContentFilter(desktopIndependentWindow:source), configuration=SCStreamConfiguration()
        configuration.ignoreShadowsSingleWindow=true;configuration.showsCursor=false
        configuration.width=Int((source.frame.width*CGFloat(filter.pointPixelScale)).rounded())
        configuration.height=Int((source.frame.height*CGFloat(filter.pointPixelScale)).rounded())
        let image=try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:configuration)
        guard windows(pid).contains(where:{ $0.id==number }) else { throw ToolRefusal("Source changed during capture") }
        return image
    }

    static func screenshot(_ number: CGWindowID, pid: pid_t, to url: URL) async throws {
        guard !FileManager.default.fileExists(atPath:url.path) else { throw ToolRefusal("Output already exists") }
        let image = try await ownedImage(number,pid:pid)
        guard let png=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else { throw ToolRefusal("PNG unavailable") }
        try png.write(to:url,options:.withoutOverwriting)
    }

    static func ocr(_ file: URL) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans","en-US"]
        try VNImageRequestHandler(url:file).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    static func pause(_ ms: Int) async { try? await Task.sleep(for:.milliseconds(ms)) }
}

struct Index: Decodable { let active: String }

@MainActor final class ToolWindow {
    let directory:URL, app:URL, previous:NSRunningApplication?, kind:String
    var client:NSRunningApplication?
    var last:[String:Any]=[:]
    init(_ kind:String) throws {
        self.kind=kind
        let kit=URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
        app=kit.appendingPathComponent("Nearpane Tool Fixture.app")
        guard Bundle(url:app)?.bundleIdentifier=="org.nearpane.acceptance.tool-window" else { throw ToolRefusal("Signed Tool Fixture.app is missing from the kit") }
        _=try ToolUI.run("/usr/bin/codesign",["--verify","--strict",app.path])
        previous=NSWorkspace.shared.frontmostApplication
        directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        do { _=try ToolUI.run("/usr/bin/open",["-n",app.path,"--args",kind,directory.path]) }
        catch {try? FileManager.default.removeItem(at:directory);throw error}
    }
    func observe(pose:Int=0) async throws -> [String:Any] {
        try Data(String(pose).utf8).write(to:directory.appendingPathComponent("pose"),options:.atomic)
        for _ in 0..<40 {
            if let data=try? Data(contentsOf:directory.appendingPathComponent("state.json")),
               let state=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
               state["session"] as? String==directory.lastPathComponent,state["kind"] as? String==kind,
               let pid=state["pid"] as? Int32,let fixture=NSRunningApplication(processIdentifier:pid),
               fixture.bundleIdentifier=="org.nearpane.acceptance.tool-window",fixture.bundleURL?.resolvingSymlinksInPath().path==app.resolvingSymlinksInPath().path {
                client=fixture;last=state
                if state["pose"] as? Int==pose,state["focused"] as? Bool==true,NSWorkspace.shared.frontmostApplication?.processIdentifier==pid {return state}
            }
            await ToolUI.pause(100)
        }
        throw ToolRefusal("Signed test window was not ready (registered=\(client != nil), key=\(last["key"] as? Bool ?? false), front=\(last["front"] as? Bool ?? false))")
    }
    func beginService() throws {
        guard kind=="selection", let client,!client.isTerminated, NSWorkspace.shared.frontmostApplication?.processIdentifier==client.processIdentifier else {
            throw ToolRefusal("Only the focused selected text client may issue the service")
        }
        try Data().write(to:directory.appendingPathComponent("perform-service"),options:.withoutOverwriting)
    }
    func selectionState() -> [String:Any]? {
        guard let client, !client.isTerminated,
              let data=try? Data(contentsOf:directory.appendingPathComponent("state.json")),
              let state=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              state["session"] as? String==directory.lastPathComponent, state["pid"] as? Int32==client.processIdentifier
        else { return nil }
        return state
    }
    func close() {
        let ownFront=client != nil && NSWorkspace.shared.frontmostApplication?.processIdentifier==client?.processIdentifier
        try? Data().write(to:directory.appendingPathComponent("close"))
        for _ in 0..<28 {
            if FileManager.default.fileExists(atPath:directory.appendingPathComponent("closed").path) &&
                (client == nil || client?.isTerminated == true) { break }
            Thread.sleep(forTimeInterval:0.06)
        }
        if FileManager.default.fileExists(atPath:directory.appendingPathComponent("closed").path) {
            try? FileManager.default.removeItem(at:directory)
            if ownFront, let previous, !previous.isTerminated {previous.activate(options:[])}
        }
    }
}

@MainActor
struct ToolContext {
    let host: NSRunningApplication
    let generation: URL, output: URL
    let appPath = "/Applications/Nearpane.app"
    init(output: String) throws {
        let env = ProcessInfo.processInfo.environment
        guard let home = env["NEARPANE_TEST_HOME"], let path = env["NEARPANE_TEST_GENERATION"] else {
            throw ToolRefusal("An installed-profile isolated lease is required")
        }
        let homeURL = URL(fileURLWithPath:home).resolvingSymlinksInPath()
        let gen = URL(fileURLWithPath:path).resolvingSymlinksInPath()
        let root = homeURL.appendingPathComponent("Library/Application Support/Nearpane Alpha Profiles").resolvingSymlinksInPath()
        let temporary = URL(fileURLWithPath:NSTemporaryDirectory()).resolvingSymlinksInPath().path
        guard let account = getpwuid(getuid()) else { throw ToolRefusal("The local account home cannot be verified") }
        let accountHome = URL(fileURLWithPath:String(cString: account.pointee.pw_dir)).resolvingSymlinksInPath()
        let lease = homeURL.deletingLastPathComponent()
        let cached = lease.deletingLastPathComponent().path == accountHome.appendingPathComponent("Library/Caches").path &&
            lease.lastPathComponent.hasPrefix("nearpane-native-acceptance.") && homeURL.lastPathComponent == "home"
        guard homeURL.path != accountHome.path,
              cached || homeURL.path.hasPrefix("/private/tmp/") || homeURL.path.hasPrefix(temporary + "/"),
              gen.deletingLastPathComponent().path == root.appendingPathComponent("generations").path,
              UUID(uuidString:gen.lastPathComponent) != nil,
              try JSONDecoder().decode(Index.self,from:Data(contentsOf:root.appendingPathComponent("profile-index.json"))).active == gen.lastPathComponent else {
            throw ToolRefusal("The generation does not belong to the designated isolated home")
        }
        let hosts = NSRunningApplication.runningApplications(withBundleIdentifier:"com.holdsnow.nearpane.alpha")
        guard hosts.count == 1, let host = hosts.first, host.bundleURL?.path == appPath, AXIsProcessTrusted() else {
            throw ToolRefusal("The sole installed Nearpane and an accessibility-capable observer are required")
        }
        let pids = try ToolUI.run("/usr/sbin/lsof",["-a","-p",String(host.processIdentifier),"-t",root.appendingPathComponent("writer.lock").path])
        guard pids.trimmingCharacters(in:.whitespacesAndNewlines) == String(host.processIdentifier) else {
            throw ToolRefusal("The installed Host does not own this isolated profile")
        }
        self.host = host; generation = gen
        self.output = URL(fileURLWithPath:output,isDirectory:true)
    }

}
