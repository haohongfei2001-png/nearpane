// Use the public macOS Services route from a real AppKit selection and read back the installed Host.
import AppKit
import ApplicationServices
import CryptoKit
import NaturalLanguage
import Translation
import Vision

struct Word: Codable, Equatable { let id: UUID; let source, translation, language: String }
struct Notebook: Decodable { let words: [Word] }

@MainActor private func serviceRoute() throws -> [String:Any] {
    let app = "/Applications/Nearpane.app"
    let dump = try ToolUI.run("/System/Library/CoreServices/pbs",["-dump_pboard"])
    let registrations = dump.components(separatedBy:"\n        {").filter { $0.contains("NSMessage = translateNearpaneSelection;") }
    let installed = registrations.filter {
        $0.contains("NSBundleIdentifier = \"com.holdsnow.nearpane.alpha\";") && $0.contains("NSBundlePath = \""+app+"\";")
    }
    let bundle = Bundle(url:URL(fileURLWithPath:app))
    let declaration = (bundle?.object(forInfoDictionaryKey:"NSServices") as? [[String:Any]])?.first { $0["NSMessage"] as? String == "translateNearpaneSelection" }
    let unique = registrations.count == 1 && installed.count == 1
    return ["phase":"serviceRegistration","status":unique ? "READY" : "BLOCKED","registeredProviders":registrations.count,
            "installedProviders":installed.count,"hasMenuContext":declaration?["NSRequiredContext"] is [String:Any],
            "portMatchesBundleName":declaration?["NSPortName"] as? String == bundle?.object(forInfoDictionaryKey:"CFBundleName") as? String,
            "reason":unique ? "Unique installed provider" : "The service directory did not identify a unique installed provider"]
}

@MainActor extension ToolContext {
    func words(_ phrase: String) throws -> [Word] {
        let path = generation.appendingPathComponent("Nearpane/sidebar-notebook.json")
        guard FileManager.default.fileExists(atPath:path.path) else { return [] }
        return try JSONDecoder().decode(Notebook.self,from:Data(contentsOf:path)).words.filter { $0.source == phrase }
    }
}

@MainActor
func translate(_ context: ToolContext) async throws -> [String:Any] {
    let route = try serviceRoute()
    guard route["status"] as? String == "READY" else { return route }
    let phrase = "The blue bicycle"
    let source = NLLanguageRecognizer.dominantLanguage(for:phrase)?.rawValue ?? "en"
    let language = await LanguageAvailability().status(from: .init(identifier:source), to: .init(identifier:"zh-Hans"))
    let languageState = language == .installed ? "installed" : language == .supported ? "supportedButNotInstalled" : "unavailable"
    let originalWords = try context.words(phrase)
    guard originalWords.isEmpty else { throw ToolRefusal("Use a fresh disposable generation for this phrase") }
    let fixture=try ToolWindow("selection")
    defer { fixture.close() }
    let state=try await fixture.observe()
    guard let pid=state["pid"] as? Int32,let number=state["window"] as? CGWindowID,let rect=state["selection"] as? String else {
        throw ToolRefusal("The signed fixture did not confirm its selection")
    }
    let selection=NSRectFromString(rect)
    let system=AXUIElementCreateSystemWide()
    guard !selection.isEmpty,let raw=ToolUI.value(system,kAXFocusedUIElementAttribute),CFGetTypeID(raw)==AXUIElementGetTypeID() else {throw ToolRefusal("No independent focused field")}
    let element=raw as! AXUIElement
    var owner:pid_t=0
    guard AXUIElementGetPid(element,&owner) == .success,owner==pid,ToolUI.value(element,kAXSelectedTextAttribute) as? String==phrase else {
        throw ToolRefusal("The independently observed selection is not the fixture phrase")
    }
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    board.setString(phrase,forType:.string)
    let priorPanels = Set(ToolUI.windows(context.host.processIdentifier).map(\.id))
    let sourcePNG = context.output.appendingPathComponent("selection.png")
    try ToolUI.screenshot(number,pid:pid,to:sourcePNG)
    let performed = NSPerformService("在 Nearpane 翻译选词",board)
    var report: [String:Any] = ["hostPID":context.host.processIdentifier,"generation":context.generation.lastPathComponent,
                                "phase":"translation","source":phrase,"sourceLanguage":source,
                                "assetStatus":languageState,"serviceDispatched":performed,"serviceRegistration":route,"selection":NSStringFromRect(selection)]
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
    if words.count == 1, let word=words.first, word.language == "zh-Hans" {
        report["translation"] = word.translation
        report["wordID"] = word.id.uuidString
        report["expectedMeaning"] = word.translation.contains("蓝") && (word.translation.contains("自行车") || word.translation.contains("单车"))
    }
    guard let sample else { report["status"]="FAIL"; report["reason"]="No new installed-Host bubble next to the selected fixture text"; return report }
    report["bubble"] = NSStringFromRect(sample.1)
    // The transient loading bubble is reused for the final text.
    await ToolUI.pause(280)
    let bubble = context.output.appendingPathComponent("bubble.png")
    let observed: String
    do {
        try ToolUI.screenshot(sample.0,pid:context.host.processIdentifier,to:bubble)
        observed = try ToolUI.ocr(bubble).joined()
    } catch {
        report["status"]="UNKNOWN"; report["reason"]="The installed bubble could not be captured and read"; return report
    }
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
    let exact = ([observed] + ax).contains { normalized($0) == normalized(word.translation) }
    let plausible = report["expectedMeaning"] as? Bool == true
    report["bubbleMatchesStoredTranslation"] = exact
    report["status"] = exact && plausible ? "PASS" : "FAIL"
    return report
}

@MainActor
func readback(_ context: ToolContext, prior: URL) async throws -> [String:Any] {
    guard let source = try JSONSerialization.jsonObject(with:Data(contentsOf:prior)) as? [String:Any],
          source["serviceDispatched"] as? Bool == true, source["notebookMatchingRows"] as? Int == 1,
          source["expectedMeaning"] as? Bool == true, source["generation"] as? String == context.generation.lastPathComponent,
          let previous = source["hostPID"] as? Int32,
          previous != context.host.processIdentifier, let phrase = source["source"] as? String,
          phrase == "The blue bicycle", let answer = source["translation"] as? String, let id = source["wordID"] as? String else {
        throw ToolRefusal("Readback requires the original translated row and a freshly relaunched Host using the same isolated generation")
    }
    let words = try context.words(phrase)
    let retained = words.count == 1 && words.first?.id.uuidString == id && words.first?.translation == answer
    // Reopen the ordinary settings window so SwiftUI reads the newly constructed notebook instance.
    try await ToolUI.openSettings(context.host)
    var entries: [String] = []
    for step in 0..<28 {
        let tree = ToolUI.nodes(context.host); entries = tree.flatMap(ToolUI.labels)
        if entries.contains(where: { $0.contains(phrase) }) && entries.contains(where: { $0.contains(answer) }) { break }
        if step == 2 || step == 10 { _ = ToolUI.press(context.host,identifier:"settings-nav-modules") }
        if step == 6 || step == 15 { _ = ToolUI.press(context.host,label:"单词本") }
        await ToolUI.pause(180)
    }
    let visible = entries.contains(where: { $0.contains(phrase) }) && entries.contains(where: { $0.contains(answer) })
    return ["phase":"wordbookAfterRelaunch","status":retained && visible ? "PASS" : "FAIL",
            "oldHostPID":previous,"hostPID":context.host.processIdentifier,"durableRowMatches":retained,
            "wordsDisplayedByRelaunchedHost":visible]
}

@main struct SelectionTrial {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in await run() }
        app.run()
    }
    @MainActor static func run() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 2 || args.count == 3 else { exit(2) }
        let path = URL(fileURLWithPath:args[1],isDirectory:true)
        let receipt = path.appendingPathComponent("result.json")
        do {
            try FileManager.default.createDirectory(at:path,withIntermediateDirectories:false)
        } catch { print("Use a fresh output directory."); exit(2) }
        let result: [String:Any]
        do {
            if args[0]=="service-route" && args.count==2 { result=try serviceRoute() }
            else {
                let ctx = try ToolContext(output:args[1])
                if args[0]=="translate" && args.count==2 { result=try await translate(ctx) }
                else if args[0]=="wordbook" && args.count==3 { result=try await readback(ctx,prior:URL(fileURLWithPath:args[2])) }
                else { throw ToolRefusal("Unknown tool trial") }
            }
        } catch { result=["phase":args[0],"status":"BLOCKED","reason":error.localizedDescription] }
        do { try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:receipt,options:.withoutOverwriting) }
        catch { exit(2) }
        print(result["status"] as? String ?? "UNKNOWN")
        exit(["PASS","READY"].contains(result["status"] as? String ?? "") ? 0 : 3)
    }
}
