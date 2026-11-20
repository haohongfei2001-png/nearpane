// Use the public macOS Services route from a real AppKit selection and read back the installed Host.
import AppKit
import ApplicationServices
import CryptoKit
import NaturalLanguage
import Translation
import Vision

struct Word: Codable, Equatable {
    let id: UUID
    let source, translation, language: String
    let sourceLanguage: String?, providerVersion: String?, sourceSHA256: String?, requestID: UUID?, committedAt: Date?
}
struct Notebook: Decodable { let words: [Word] }

private func kernelBirth(_ pid:pid_t)->UInt64? {
    var state=proc_bsdinfo()
    let size=Int32(MemoryLayout.size(ofValue:state))
    guard proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&state,size)==size,state.pbi_pid==UInt32(pid),
          state.pbi_start_tvsec>0 else { return nil }
    return state.pbi_start_tvsec*1_000_000+state.pbi_start_tvusec
}

@MainActor private func hostStages(pid: pid_t, phrase: String, after: Double, request: UUID? = nil) -> [String:Any] {
    let hash = SHA256.hash(data: Data(phrase.utf8)).map { String(format: "%02x", $0) }.joined()
    let predicate = "processID == \(pid) AND subsystem == 'com.holdsnow.nearpane.alpha' AND category == 'LocalToolStage'"
    guard let logs = try? ToolUI.run("/usr/bin/log", ["show", "--style", "compact", "--last", "1m", "--predicate", predicate]),
          let pattern = try? NSRegularExpression(pattern: #"toolStage id=([0-9A-Fa-f-]{36}) stage=([a-zA-Z]+) hash=(-|[0-9a-f]{64}) uptime=([0-9.]+)"#) else {
        return ["available":false]
    }
    let records = logs.split(separator:"\n").compactMap { line -> [String]? in
        let text = String(line) as NSString
        guard let match = pattern.firstMatch(in: text as String, range:NSRange(location:0,length:text.length)) else { return nil }
        let fields = (1...4).map { text.substring(with:match.range(at:$0)) }
        guard (Double(fields[3]) ?? -1) >= after else { return nil }
        return fields
    }
    if let request {
        let subset=records.filter{$0[0] == request.uuidString}.map { ["stage":$0[1],"sha256":$0[2],"uptime":$0[3]] }
        return ["available":true,"requestID":request.uuidString,"stages":subset]
    }
    let callbacks = records.filter { $0[1] == "serviceCallback" && $0[2] == hash }
    guard callbacks.count == 1, let id = callbacks.first?.first else { return ["available":false,"callbackMatches":callbacks.count] }
    return ["available":true,"requestID":id,"stages":records.filter { $0[0] == id }.map { ["stage":$0[1], "sha256":$0[2], "uptime":$0[3]] }]
}

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
    guard let hostBirth=kernelBirth(context.host.processIdentifier) else { throw ToolRefusal("Installed Host generation unavailable") }
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
    func sourceFocused() -> Bool {
        guard let client=fixture.client,!client.isTerminated,NSWorkspace.shared.frontmostApplication == client,
              let state=try? JSONSerialization.jsonObject(with:Data(contentsOf:fixture.directory.appendingPathComponent("state.json"))) as? [String:Any],
              state["session"] as? String == fixture.directory.lastPathComponent, state["pid"] as? Int32==pid,
              state["window"] as? UInt32==number,state["front"] as? Bool==true,state["key"] as? Bool==true,state["focused"] as? Bool==true,
              let raw=ToolUI.value(AXUIElementCreateSystemWide(),kAXFocusedUIElementAttribute),CFGetTypeID(raw)==AXUIElementGetTypeID() else{return false}
        var actual:pid_t=0
        return AXUIElementGetPid(raw as! AXUIElement,&actual) == .success && actual==pid
    }
    let clientSelection=NSRectFromString(rect)
    let system=AXUIElementCreateSystemWide()
    guard !clientSelection.isEmpty,let raw=ToolUI.value(system,kAXFocusedUIElementAttribute),CFGetTypeID(raw)==AXUIElementGetTypeID() else {throw ToolRefusal("No independent focused field")}
    let element=raw as! AXUIElement
    var owner:pid_t=0
    guard AXUIElementGetPid(element,&owner) == .success,owner==pid,ToolUI.value(element,kAXSelectedTextAttribute) as? String==phrase else {
        throw ToolRefusal("The independently observed selection is not the fixture phrase")
    }
    var axBounds=CGRect.zero
    if let range=ToolUI.value(element,kAXSelectedTextRangeAttribute) {
        var rawBounds:CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(element,kAXBoundsForRangeParameterizedAttribute as CFString,range,&rawBounds) == .success,
           let rawBounds,CFGetTypeID(rawBounds)==AXValueGetTypeID() {
            _=AXValueGetValue(rawBounds as! AXValue,.cgRect,&axBounds)
        }
    }
    let selection=axBounds.isEmpty ? clientSelection:axBounds
    let priorPanels = Set(ToolUI.windows(context.host.processIdentifier).map(\.id))
    let sourcePNG = context.output.appendingPathComponent("selection.png")
    try await ToolUI.screenshot(number,pid:pid,to:sourcePNG)
    let pointer = CGEvent(source: nil)?.location
    let started = ProcessInfo.processInfo.systemUptime
    guard sourceFocused() else { throw ToolRefusal("The fixture lost its selected input before Services dispatch") }
    let performed = try await fixture.requestService()
    var report: [String:Any] = ["hostPID":context.host.processIdentifier,"hostBirth":hostBirth,"generation":context.generation.lastPathComponent,
                                "phase":"translation","source":phrase,"sourceLanguage":source,
                                "assetStatus":languageState,"serviceDispatched":performed,"serviceRegistration":route,"selection":NSStringFromRect(selection),
                                "clientSelection":NSStringFromRect(clientSelection),"axBoundsAvailable":!axBounds.isEmpty,"rowsBefore":originalWords.count]
    guard performed else { report["status"]="FAIL"; report["reason"]="macOS could not deliver the declared Service"; return report }
    var sample: (CGWindowID,CGRect)?
    var pointerSample: (CGWindowID,CGRect)?
    var words: [Word] = []
    var observedFrames=[CGWindowID:String]()
    for _ in 0..<180 {
        guard !context.host.isTerminated else { throw ToolRefusal("Host exited during translation") }
        let panels=ToolUI.windows(context.host.processIdentifier).filter { !priorPanels.contains($0.id) && $0.level == NSWindow.Level.popUpMenu.rawValue }
        for panel in panels { observedFrames[panel.id]=NSStringFromRect(panel.bounds) }
        if let panel = panels.first(where: {
            !priorPanels.contains($0.id) && $0.level == NSWindow.Level.popUpMenu.rawValue
                && $0.bounds.width > 15 && $0.bounds.width < 450 && $0.bounds.height < 230
                && abs($0.bounds.minX-selection.minX) <= 4
                && min(abs($0.bounds.minY-selection.maxY),abs($0.bounds.maxY-selection.minY)) <= 11
        }) {
            sample = (panel.id,panel.bounds)

        }
        if let pointer, let panel = panels.first(where: { $0.bounds.width > 15 && $0.bounds.width < 450 &&
            $0.bounds.height < 230 && $0.bounds.insetBy(dx:-12,dy:-12).contains(pointer) }) {
            pointerSample = (panel.id,panel.bounds)
        }
        words = try context.words(phrase)
        if (sample != nil || pointerSample != nil) && ((!words.isEmpty) || language != .installed) { break }
        await ToolUI.pause(90)
    }
    report["newPopupFrames"]=observedFrames.values.sorted()
    await ToolUI.pause(220)
    var stages = hostStages(pid: context.host.processIdentifier, phrase: phrase, after: started)
    for _ in 0..<3 {
        let log = stages["stages"] as? [[String:String]] ?? []
        if log.contains(where:{ $0["stage"] == "panelVisible" }) &&
            log.contains(where:{ ["wordCommitted","modelMissing","modelUnsupported"].contains($0["stage"] ?? "") }) { break }
        await ToolUI.pause(200)
        stages = hostStages(pid: context.host.processIdentifier, phrase: phrase, after: started)
    }
    report["hostHandoff"] = stages
    let evidence = stages["stages"] as? [[String:String]] ?? []
    let ordered = evidence.compactMap { $0["stage"] }
    let request = (stages["requestID"] as? String).flatMap(UUID.init(uuidString:))
    let sourceDigest = TranslationProof.digest(phrase)
    report["serviceRequestHandoff"] = TranslationProof.follows(evidence,[("serviceCallback",sourceDigest),("requestQueued",sourceDigest),("hostReceived",sourceDigest)]) ? "PASS":"UNKNOWN"
    if sample == nil, ordered.contains("anchorPointer") { sample = pointerSample }
    report["notebookMatchingRows"] = words.count
    if words.count == 1, let word=words.first, word.language == "zh-Hans" {
        report["translation"] = word.translation
        report["wordID"] = word.id.uuidString
        report["requestID"] = word.requestID?.uuidString
        report["providerVersion"] = word.providerVersion
        report["sourceHash"] = word.sourceSHA256
        report["expectedMeaning"] = word.translation.contains("蓝") && (word.translation.contains("自行车") || word.translation.contains("单车"))
    }
    guard let originalSample=sample,let request,
          let current=ToolUI.windows(context.host.processIdentifier).first(where:{$0.id==originalSample.0 && $0.level==NSWindow.Level.popUpMenu.rawValue})
    else { report["status"]="UNKNOWN"; report["reason"]="A unique service request or adjacent installed Host window was not observed"; return report }
    let bubbleSurface=(current.id,current.bounds)
    let atSelection = abs(current.bounds.minX-selection.minX) <= 4 &&
        min(abs(current.bounds.minY-selection.maxY),abs(current.bounds.maxY-selection.minY)) <= 11
    let atPointer = pointer.map { current.bounds.insetBy(dx:-12,dy:-12).contains($0) } ?? false
    guard (atSelection && ordered.contains("anchorSelection")) || (atPointer && ordered.contains("anchorPointer")) else {
        report["status"]="UNKNOWN";report["reason"]="The final bubble could not be matched to the observed selection or pointer";return report
    }
    let expected = words.count == 1 ? words[0].translation : ordered.contains("modelMissing") ?
        "请先在 macOS 翻译设置中下载所需语言。" : ordered.contains("modelUnsupported") ? "当前系统不支持这组语言的本地翻译。" : ""
    let panelHash=TranslationProof.panel(request,pid:context.host.processIdentifier,window:bubbleSurface.0,text:expected)
    let isBound = !expected.isEmpty && evidence.contains { $0["stage"] == "panelVisible" && $0["sha256"] == panelHash }
    func panelCurrent() -> Bool {
        guard let rows=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] else { return false }
        let interior=bubbleSurface.1.insetBy(dx:2,dy:2)
        for row in rows {
            guard let data=row[kCGWindowBounds as String] as? NSDictionary,let rect=CGRect(dictionaryRepresentation:data) else{return false}
            if row[kCGWindowNumber as String] as? UInt32==bubbleSurface.0 {
                return row[kCGWindowOwnerPID as String] as? pid_t==context.host.processIdentifier &&
                    row[kCGWindowLayer as String] as? Int==NSWindow.Level.popUpMenu.rawValue && rect==bubbleSurface.1
            }
            if (row[kCGWindowAlpha as String] as? Double ?? 1)>0 && rect.intersects(interior) {return false}
        }
        return false
    }
    guard isBound, panelCurrent(), sourceFocused() else {
        report["status"]="UNKNOWN";report["reason"]="Could not bind this non-key visible window, its content and foreground fixture to the same Services request";return report
    }
    report["panelWindow"]=bubbleSurface.0;report["panelContentSHA256"]=TranslationProof.digest(expected)
    report["fixtureFocusBefore"]=true
    report["serviceUptime"]=started
    report["bubble"] = NSStringFromRect(bubbleSurface.1)
    // The transient loading bubble is reused for the final text.
    await ToolUI.pause(280)
    let bubble = context.output.appendingPathComponent("bubble.png")
    let observed: String
    do {
        try await ToolUI.screenshot(bubbleSurface.0,pid:context.host.processIdentifier,to:bubble)
        observed = try ToolUI.ocr(bubble).joined()
    } catch {
        report["status"]="UNKNOWN"; report["reason"]="The installed bubble could not be captured and read"; return report
    }
    func normalized(_ text:String) -> String {
        text.filter { $0.isLetter || $0.isNumber }.lowercased()
    }
    guard panelCurrent(), sourceFocused() else {
        try? FileManager.default.removeItem(at:bubble)
        report["status"]="UNKNOWN";report["reason"]="Panel identity or document focus changed during the observation";return report
    }
    report["fixtureFocusAfter"]=true
    let ax = ToolUI.nodes(context.host).filter { node in
        guard ToolUI.value(node,kAXIdentifierAttribute) as? String == "nearpane-translation-content-" + request.uuidString, let r = ToolUI.frame(node) else { return false }
        return bubbleSurface.1.insetBy(dx:-2,dy:-2).contains(r) && !r.isEmpty
    }.flatMap(ToolUI.labels)
    if language != .installed && words.isEmpty {
        let explained = ([observed] + ax).contains { normalized($0)==normalized(expected) ||
            (ordered.contains("modelMissing") && ($0.contains("下载") || $0.contains("下載"))) }
        report["visibleNonactivatingBubble"] = explained ? "PASS":"UNKNOWN"
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
    report["visibleNonactivatingBubble"] = exact ? "PASS":"UNKNOWN"
    let orderedChain = TranslationProof.translated(evidence,source:phrase,answer:word.translation,id:request,pid:context.host.processIdentifier,window:bubbleSurface.0)
    report["orderedResultChain"]=orderedChain
    let stored = words[0]
    let linked = stored.requestID?.uuidString == stages["requestID"] as? String && stored.providerVersion != nil &&
        stored.sourceLanguage == source && stored.committedAt != nil && stored.sourceSHA256 == sourceDigest
    report["status"] = exact && plausible && linked && orderedChain ? "PASS" : "FAIL"
    return report
}

@MainActor
func readback(_ context: ToolContext, prior: URL) async throws -> [String:Any] {
    guard let source = try JSONSerialization.jsonObject(with:Data(contentsOf:prior)) as? [String:Any],
          source["serviceDispatched"] as? Bool == true, source["orderedResultChain"] as? Bool == true,
          source["fixtureFocusBefore"] as? Bool == true, source["fixtureFocusAfter"] as? Bool == true, source["generation"] as? String == context.generation.lastPathComponent,
          let previous = source["hostPID"] as? Int32, let oldBirth=source["hostBirth"] as? UInt64,
          let newBirth=kernelBirth(context.host.processIdentifier), (previous != context.host.processIdentifier || oldBirth != newBirth), let phrase = source["source"] as? String,
          phrase == "The blue bicycle" else {
        throw ToolRefusal("Readback requires the original request and a relaunched Host using the same isolated generation")
    }
    let words = try context.words(phrase)
    guard source["notebookMatchingRows"] as? Int == 1, source["expectedMeaning"] as? Bool == true,
          let answer=source["translation"] as? String,let id=source["wordID"] as? String else {
        return ["phase":"wordbookAfterRelaunch","status":words.isEmpty ? "BLOCKED":"UNKNOWN","rowsAfterRelaunch":words.count,
                "oldHostPID":previous,"hostPID":context.host.processIdentifier,"reason":"No pre-restart row identity for comparison"]
    }
    let retained = words.count == 1 && words.first?.id.uuidString == id && words.first?.translation == answer &&
        words.first?.requestID?.uuidString == source["requestID"] as? String && words.first?.providerVersion != nil &&
        words.first?.providerVersion == source["providerVersion"] as? String && words.first?.committedAt != nil
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
    guard let request=(source["requestID"] as? String).flatMap(UUID.init(uuidString:)), let start=source["serviceUptime"] as? Double else {
        throw ToolRefusal("The source receipt has no attributed request or event time")
    }
    let fresh=hostStages(pid:context.host.processIdentifier,phrase:phrase,after:start,request:request)
    let reopened=TranslationProof.follows(fresh["stages"] as? [[String:String]] ?? [],[("wordReopened",TranslationProof.digest(answer))])
    return ["phase":"wordbookAfterRelaunch","status":retained && visible && reopened ? "PASS" : "UNKNOWN",
            "oldHostBirth":oldBirth,"hostBirth":newBirth,"freshHostReadback":reopened,"requestID":request.uuidString,"resultSHA256":TranslationProof.digest(answer),
            "oldHostPID":previous,"hostPID":context.host.processIdentifier,"durableRowMatches":retained,"rowsAfterRelaunch":words.count,
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
