// Use the public macOS Services route from a real AppKit selection and read back the installed Host.
import AppKit
import ApplicationServices
import CryptoKit
import NaturalLanguage
import Translation
import Vision

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

    static func screenshot(_ number: CGWindowID, pid: pid_t, to url: URL) throws {
        guard number != 0, windows(pid).contains(where: { $0.id == number }), !FileManager.default.fileExists(atPath:url.path) else {
            throw ToolRefusal("Owned window no longer exists or output already exists")
        }
        _ = try run("/usr/sbin/screencapture",["-x","-o","-l",String(number),url.path])
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

struct Word: Codable, Equatable { let id: UUID; let source, translation, language: String }
struct Notebook: Decodable { let words: [Word] }
struct Index: Decodable { let active: String }

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
        let fm = FileManager.default
        let homeURL = URL(fileURLWithPath:home).resolvingSymlinksInPath()
        let gen = URL(fileURLWithPath:path).resolvingSymlinksInPath()
        let root = homeURL.appendingPathComponent("Library/Application Support/Nearpane Alpha Profiles").resolvingSymlinksInPath()
        guard homeURL != fm.homeDirectoryForCurrentUser.resolvingSymlinksInPath(),
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
    func words(_ phrase: String) throws -> [Word] {
        let path = generation.appendingPathComponent("Nearpane/sidebar-notebook.json")
        guard FileManager.default.fileExists(atPath:path.path) else { return [] }
        return try JSONDecoder().decode(Notebook.self,from:Data(contentsOf:path)).words.filter { $0.source == phrase }
    }
}

@MainActor
func translate(_ context: ToolContext) async throws -> [String:Any] {
    let phrase = "The blue bicycle"
    let source = NLLanguageRecognizer.dominantLanguage(for:phrase)?.rawValue ?? "en"
    let language = await LanguageAvailability().status(from: .init(identifier:source), to: .init(identifier:"zh-Hans"))
    let languageState = language == .installed ? "installed" : language == .supported ? "supportedButNotInstalled" : "unavailable"
    let originalWords = try context.words(phrase)
    guard originalWords.isEmpty else { throw ToolRefusal("Use a fresh disposable generation for this phrase") }
    let app = NSApplication.shared
    app.setActivationPolicy(.regular); app.finishLaunching()
    let previous = NSWorkspace.shared.frontmostApplication
    let window = NSWindow(contentRect:NSRect(x:0,y:0,width:460,height:135),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed = false; window.title = "Nearpane selection fixture"
    let field = NSTextView(frame:NSRect(x:28,y:30,width:395,height:70))
    field.isRichText = false; field.isEditable = true; field.isSelectable = true
    field.font = .systemFont(ofSize:23); field.string = phrase
    window.contentView?.addSubview(field); window.center()
    window.makeKeyAndOrderFront(nil); window.makeFirstResponder(field)
    field.setSelectedRange(NSRange(location:0,length:(phrase as NSString).length))
    app.activate(ignoringOtherApps:true)
    defer {
        let ownsForeground = NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
        window.close()
        if ownsForeground, let previous, !previous.isTerminated { previous.activate(options:[]) }
    }
    for _ in 0..<30 {
        if window.isKeyWindow && NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() { break }
        await ToolUI.pause(100)
    }
    guard window.isKeyWindow, NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(),
          let primary = NSScreen.screens.first else { throw ToolRefusal("The test text field did not become key") }
    let rect = field.firstRect(forCharacterRange: field.selectedRange(), actualRange:nil)
    let selection = CGRect(x:rect.minX,y:primary.frame.maxY-rect.maxY,width:rect.width,height:rect.height)
    guard !selection.isEmpty else { throw ToolRefusal("The fixture selection has no independent bounds") }
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    board.setString(phrase,forType:.string)
    let priorPanels = Set(ToolUI.windows(context.host.processIdentifier).map(\.id))
    let sourcePNG = context.output.appendingPathComponent("selection.png")
    try ToolUI.screenshot(CGWindowID(window.windowNumber),pid:getpid(),to:sourcePNG)
    let performed = NSPerformService("在 Nearpane 翻译选词",board)
    var report: [String:Any] = ["hostPID":context.host.processIdentifier,"phase":"translation","source":phrase,"sourceLanguage":source,
                                "assetStatus":languageState,"serviceDispatched":performed,"selection":NSStringFromRect(selection)]
    guard performed else { report["status"]="FAIL"; report["reason"]="macOS could not deliver the declared Service"; return report }
    var sample: (CGWindowID,CGRect)?
    var words: [Word] = []
    for _ in 0..<70 {
        guard !context.host.isTerminated else { throw ToolRefusal("Host exited during translation") }
        if let panel = ToolUI.windows(context.host.processIdentifier).first(where: {
            !priorPanels.contains($0.id) && $0.level == NSWindow.Level.popUpMenu.rawValue
                && $0.bounds.width > 15 && $0.bounds.width < 450 && $0.bounds.height < 230
                && abs($0.bounds.minX-selection.minX) <= 4
                && min(abs($0.bounds.minY-selection.maxY),abs($0.bounds.maxY-selection.minY)) <= 11
        }) { sample = (panel.id,panel.bounds) }
        words = try context.words(phrase)
        if sample != nil && ((!words.isEmpty) || language != .installed) { break }
        await ToolUI.pause(90)
    }
    report["notebookMatchingRows"] = words.count
    guard let sample else { report["status"]="FAIL"; report["reason"]="No new installed-Host bubble next to the selected fixture text"; return report }
    report["bubble"] = NSStringFromRect(sample.1)
    // The transient loading bubble is reused for the final text.
    await ToolUI.pause(280)
    let bubble = context.output.appendingPathComponent("bubble.png")
    try ToolUI.screenshot(sample.0,pid:context.host.processIdentifier,to:bubble)
    let observed = try ToolUI.ocr(bubble).joined()
    func normalized(_ text:String) -> String {
        text.filter { $0.isLetter || $0.isNumber }.lowercased()
    }
    let ax = ToolUI.nodes(context.host).filter { node in
        guard let r = ToolUI.frame(node) else { return false }
        return sample.1.insetBy(dx:-2,dy:-2).contains(r) && !r.isEmpty
    }.flatMap(ToolUI.labels)
    if language != .installed && words.isEmpty {
        let explained = ([observed] + ax).contains { $0.contains("下载") || $0.contains("下載") }
        report["missingLanguageNoticeObserved"] = explained
        report["status"] = explained ? "BLOCKED" : "UNKNOWN"
        report["reason"] = "Offline translation languages are not installed"
        return report
    }
    guard words.count == 1, let word = words.first, word.language == "zh-Hans" else {
        report["status"]="FAIL"; report["reason"]="The isolated wordbook has no unique translated row"; return report
    }
    report["translation"] = word.translation; report["wordID"] = word.id.uuidString
    let exact = ([observed] + ax).contains { normalized($0) == normalized(word.translation) }
    let plausible = word.translation.contains("蓝") && (word.translation.contains("自行车") || word.translation.contains("单车"))
    report["bubbleMatchesStoredTranslation"] = exact; report["expectedMeaning"] = plausible
    report["status"] = exact && plausible ? "PASS" : "FAIL"
    return report
}

@MainActor
func readback(_ context: ToolContext, prior: URL) async throws -> [String:Any] {
    guard let source = try JSONSerialization.jsonObject(with:Data(contentsOf:prior)) as? [String:Any],
          source["status"] as? String == "PASS", let previous = source["hostPID"] as? Int32,
          previous != context.host.processIdentifier, let phrase = source["source"] as? String,
          phrase == "The blue bicycle", let answer = source["translation"] as? String, let id = source["wordID"] as? String else {
        throw ToolRefusal("Readback requires a successful original translation and a freshly relaunched Host")
    }
    let words = try context.words(phrase)
    let retained = words.count == 1 && words.first?.id.uuidString == id && words.first?.translation == answer
    // Reopen the ordinary settings window so SwiftUI reads the newly constructed notebook instance.
    NSWorkspace.shared.open(URL(fileURLWithPath:context.appPath))
    var entries: [String] = []
    for step in 0..<28 {
        let tree = ToolUI.nodes(context.host); entries = tree.flatMap(ToolUI.labels)
        if entries.contains(where: { $0.contains(phrase) }) && entries.contains(where: { $0.contains(answer) }) { break }
        if step == 2 || step == 10 { _ = ToolUI.press(context.host,label:"模块") }
        if step == 6 || step == 15 { _ = ToolUI.press(context.host,label:"单词本") }
        await ToolUI.pause(180)
    }
    let visible = entries.contains(where: { $0.contains(phrase) }) && entries.contains(where: { $0.contains(answer) })
    return ["phase":"wordbookAfterRelaunch","status":retained && visible ? "PASS" : "FAIL",
            "oldHostPID":previous,"hostPID":context.host.processIdentifier,"durableRowMatches":retained,
            "wordsDisplayedByRelaunchedHost":visible]
}

@main struct SelectionTrial {
    @MainActor static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 2 || args.count == 3 else { exit(2) }
        let path = URL(fileURLWithPath:args[1],isDirectory:true)
        let receipt = path.appendingPathComponent("result.json")
        do {
            try FileManager.default.createDirectory(at:path,withIntermediateDirectories:false)
        } catch { print("Use a fresh output directory."); exit(2) }
        let result: [String:Any]
        do {
            let ctx = try ToolContext(output:args[1])
            if args[0]=="translate" && args.count==2 { result=try await translate(ctx) }
            else if args[0]=="wordbook" && args.count==3 { result=try await readback(ctx,prior:URL(fileURLWithPath:args[2])) }
            else { throw ToolRefusal("Unknown tool trial") }
        } catch { result=["phase":args[0],"status":"BLOCKED","reason":error.localizedDescription] }
        do { try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:receipt,options:.withoutOverwriting) }
        catch { exit(2) }
        print(result["status"] as? String ?? "UNKNOWN")
        exit(result["status"] as? String == "PASS" ? 0 : 3)
    }
}
