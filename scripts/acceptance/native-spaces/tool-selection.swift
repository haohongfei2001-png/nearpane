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

@MainActor private func hostStages(pid: pid_t, phrase: String, after: Double, request: UUID? = nil, dispatch: [String:Double]? = nil) -> [String:Any] {
    let hash = SHA256.hash(data: Data(phrase.utf8)).map { String(format: "%02x", $0) }.joined()
    let predicate = "processID == \(pid) AND subsystem == 'com.holdsnow.nearpane.alpha' AND (category == 'LocalToolStage' OR category == 'HostOpen')"
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
    var result:[String:Any] = ["available":true,"requestID":id,"stages":records.filter { $0[0] == id }.map { ["stage":$0[1], "sha256":$0[2], "uptime":$0[3]] }]
    if let dispatch, let start=dispatch["before"], let end=dispatch["after"], end>=start,
       let opens=try? NSRegularExpression(pattern:#"hostOpen phase=(open|reopen) marker=(service|login|background|unmarked) uptime=([0-9.]+)"#) {
        result["openDelegateWithinService"] = logs.split(separator:"\n").compactMap { line -> [String:String]? in
            let text=String(line) as NSString
            guard let match=opens.firstMatch(in:text as String,range:NSRange(location:0,length:text.length)),
                  let time=Double(text.substring(with:match.range(at:3))),time>=start,time<=end else {return nil}
            return ["phase":text.substring(with:match.range(at:1)),"marker":text.substring(with:match.range(at:2)),"uptime":String(time)]
        }
    }
    return result
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
    func focus()->TranslationSourceWitness { translationSource(fixture,pid,number,element,phrase,host:context.host.processIdentifier) }
    func sameHost()->Bool { !context.host.isTerminated && kernelBirth(context.host.processIdentifier)==hostBirth }
    let beforeService=focus()
    guard beforeService.confirmed else {throw ToolRefusal("Fixture input, exact external AX selection or foreground changed before dispatch")}
    try fixture.beginService()
    // Observe the live surface first. Unified log readback and Vision OCR may outlive the panel.
    var samples=[TranslationPanelSample](), frames=[CGWindowID:Set<String>](), ambiguous=0
    var words=[Word](), firstFrame:Double?, completedFrame:Double?, attempt=0
    let offsets=[0.0,0.35,1.0,2.2,4.0,6.1]
    let wallLimit=started+(language == .installed ? 19.0:7.5)
    while ProcessInfo.processInfo.systemUptime < wallLimit && sameHost() {
        let now=ProcessInfo.processInfo.systemUptime
        words=try context.words(phrase)
        if !words.isEmpty && completedFrame==nil {
            completedFrame=now;attempt=0
        }
        let panels=ToolUI.windows(context.host.processIdentifier).filter {
            !priorPanels.contains($0.id) && $0.level==NSWindow.Level.popUpMenu.rawValue &&
            $0.bounds.width>15 && $0.bounds.width<450 && $0.bounds.height>0 && $0.bounds.height<230
        }
        func nearSelection(_ r:CGRect)->Bool {
            abs(r.minX-selection.minX)<=4 && min(abs(r.minY-selection.maxY),abs(r.maxY-selection.minY))<=11
        }
        for row in panels {frames[row.id,default:[]].insert(NSStringFromRect(row.bounds))}
        let qualified=panels.filter { row in
            nearSelection(row.bounds) || pointer.map {nearTranslationPointer(row.bounds,$0)}==true
        }
        if qualified.count>1 {ambiguous+=1}
        if qualified.count==1,let candidate=qualified.first {
            if firstFrame==nil {firstFrame=now}
            let epoch=completedFrame ?? firstFrame ?? now
            let limit=language == .installed && words.isEmpty ? 1:offsets.count
            if attempt<limit && now>=epoch+offsets[attempt] {
                attempt+=1
                samples.append(await sampleTranslationPanel(host:context.host.processIdentifier,fixture:pid,
                    number:candidate.id,rect:candidate.bounds,selection:nearSelection(candidate.bounds),
                    pointer:pointer,focus:focus,sameHost:sameHost))
            }
            if attempt==offsets.count {break}
        }
        await ToolUI.pause(60)
    }
    let fixtureEnd=fixture.selectionState()
    let attempted=fixtureEnd?["serviceAttempted"] as? Bool
    let performed=fixtureEnd?["serviceDispatched"] as? Bool
    var report:[String:Any]=["hostPID":context.host.processIdentifier,"hostBirth":hostBirth,"generation":context.generation.lastPathComponent,
        "phase":"translation","observationContract":"live-panel-before-log-v3","source":phrase,"sourceLanguage":source,"assetStatus":languageState,
        "serviceDispatched":performed==true,"fixtureDispatchConfirmed":attempted==true && performed != nil,
        "serviceRegistration":route,"selection":NSStringFromRect(selection),"clientSelection":NSStringFromRect(clientSelection),
        "axBoundsAvailable":!axBounds.isEmpty,"rowsBefore":originalWords.count,"sourceBeforeDispatch":beforeService.checks,
        "serviceUptime":started,"ambiguousPanelSamples":ambiguous,"newPopupFrames":frames.values.flatMap{$0}.sorted(),
        "windowObservations":frames.keys.sorted().map{["window":$0,"frames":Array(frames[$0] ?? []).sorted()] as [String:Any]},
        "fixtureServiceTimes":fixtureEnd?["serviceTimes"] ?? [:],"fixtureSelectionAcrossService":fixtureEnd?["selectionAcrossService"] ?? [:]]
    words=try context.words(phrase)
    let dispatch=fixtureEnd?["serviceTimes"] as? [String:Double]
    var stages = hostStages(pid: context.host.processIdentifier, phrase: phrase, after: started, dispatch: dispatch)
    for _ in 0..<3 {
        let log = stages["stages"] as? [[String:String]] ?? []
        if log.contains(where:{ $0["stage"] == "panelVisible" }) &&
            log.contains(where:{ ["wordCommitted","modelMissing","modelUnsupported"].contains($0["stage"] ?? "") }) { break }
        await ToolUI.pause(200)
        stages = hostStages(pid: context.host.processIdentifier, phrase: phrase, after: started, dispatch: dispatch)
    }
    report["hostHandoff"] = stages
    let evidence = stages["stages"] as? [[String:String]] ?? []
    let ordered = evidence.compactMap { $0["stage"] }
    let request = (stages["requestID"] as? String).flatMap(UUID.init(uuidString:))
    let sourceDigest = TranslationProof.digest(phrase)
    report["serviceRequestHandoff"] = TranslationProof.follows(evidence,[("serviceCallback",sourceDigest),("requestQueued",sourceDigest),("hostReceived",sourceDigest)]) ? "PASS":"UNKNOWN"

    report["notebookMatchingRows"] = words.count
    if words.count == 1, let word=words.first, word.language == "zh-Hans" {
        report["translation"] = word.translation
        report["wordID"] = word.id.uuidString
        report["requestID"] = word.requestID?.uuidString
        report["providerVersion"] = word.providerVersion
        report["sourceHash"] = word.sourceSHA256
        report["expectedMeaning"] = word.translation.contains("蓝") && (word.translation.contains("自行车") || word.translation.contains("单车"))
    }
    let expected=words.count==1 ? words[0].translation : ordered.contains("modelMissing") ?
        "请先在 macOS 翻译设置中下载所需语言。" : ordered.contains("modelUnsupported") ? "当前系统不支持这组语言的本地翻译。" : ""
    let terminal=words.count==1 ? "wordCommitted" : ordered.contains("modelMissing") ? "modelMissing" : "modelUnsupported"
    let content=TranslationProof.digest(TranslationProof.normalized(expected))
    var details=[[String:Any]](), winner:TranslationPanelSample?, signedHostTookFocus=false, unclearPostReturnSource=false, contentSeen=false
    var genericWindowSeen=false, exactSelectionSeen=false, confirmedSourceSample=false
    var genericContentSample:TranslationPanelSample?
    let hasOrigin=ordered.contains("serviceOriginBound")
    let unverified=ordered.contains("serviceCallerUnverified") || ordered.contains("serviceSelectionUnverified")
    report["serviceOriginAttribution"]=hasOrigin ? "PASS" : unverified ? "BLOCKED_UNVERIFIED" : "UNKNOWN"
    let serviceReturn=(fixtureEnd?["serviceTimes"] as? [String:Double])?["after"]
    for sample in samples {
        let declared=request.flatMap { TranslationProof.presentation(evidence,source:phrase,answer:expected,terminal:terminal,
            id:$0,pid:context.host.processIdentifier,window:sample.number,begin:sample.begin,end:sample.end) }
        let axExact:Bool
        if let request,let axEnd=sample.axEnd,sample.labels.count==1,sample.labels[request]?.contains(content)==true,
           let declared {
            axExact=TranslationProof.presentation(evidence,source:phrase,answer:expected,terminal:terminal,id:request,
                pid:context.host.processIdentifier,window:sample.number,begin:sample.begin,end:axEnd)==declared
        } else {axExact=false}
        let optical=sample.textInImage(expected)
        let verdict=TranslationPanelVerdict(isBound:declared != nil,
            panelCurrent:sample.beforeStack.clear && sample.afterStack.clear,
            sourceFocused:sample.beforeFocus.confirmed && sample.afterFocus.confirmed,
            anchorMatches:(declared=="anchorSelection" && sample.selection) || (["anchorPointer","anchorFeedbackPointer"].contains(declared ?? "") && sample.pointer),
            hostSameGeneration:sample.sameHost,imageCaptured:sample.image != nil,contentMatches:optical.matches || (axExact && optical.visibleText))
        var item=sample.metadata
        item["checks"]=verdict.fields;item["exactRequestAXText"]=axExact;item["exactOCR"]=optical.matches;item["textSeenInImage"]=optical.visibleText
        let phaseBound=declared != nil && verdict.panelCurrent && verdict.hostSameGeneration && verdict.anchorMatches
        item["boundPanelContentObserved"]=phaseBound && verdict.imageCaptured && verdict.contentMatches
        if item["boundPanelContentObserved"] as? Bool==true {contentSeen=true}
        if declared=="anchorFeedbackPointer", phaseBound {
            genericWindowSeen=true
            if genericContentSample==nil && verdict.imageCaptured && verdict.contentMatches {genericContentSample=sample}
        }
        if phaseBound,let serviceReturn,sample.begin>=serviceReturn {
            if verdict.sourceFocused {confirmedSourceSample=true}
            if sample.beforeFocus.leftForHost && sample.afterFocus.leftForHost {signedHostTookFocus=true}
            if !sample.beforeFocus.confirmed || !sample.afterFocus.confirmed {unclearPostReturnSource=true}
        }
        let sourceQualified=verdict.passed && TranslationProof.sourceAnchor(declared)
        if sourceQualified && hasOrigin && declared=="anchorSelection" {exactSelectionSeen=true}
        item["declaredAnchor"]=declared ?? "unbound";item["qualified"]=sourceQualified
        details.append(item)
        if winner==nil && sourceQualified {winner=sample}
    }
    report["panelSamples"]=details
    report["anchorDeclarations"]=ordered.filter {TranslationProof.anchors.contains($0)}
    let usedGeneric=ordered.contains("anchorFeedbackPointer")
    let missingPointer=unverified && ordered.contains("feedbackPointerUnavailable")
    let revokedPointer=unverified && ordered.contains("feedbackPointerRevoked")
    report["genericFeedbackWindow"]=genericWindowSeen ? "PASS" : usedGeneric ? "UNKNOWN" :
        missingPointer ? "BLOCKED_POINTER_UNAVAILABLE" : revokedPointer ? "BLOCKED_CONTEXT_CHANGED" : "NOT_USED"
    report["genericFeedbackContent"]=genericContentSample != nil ? "PASS" : usedGeneric ? "UNKNOWN" : "NOT_USED"
    report["preciseSelectionPlacement"]=exactSelectionSeen ? "PASS" : unverified ? "BLOCKED_UNVERIFIED_SOURCE" : "UNKNOWN"
    report["panelChecks"]=["isBound","panelCurrent","sourceFocused","anchorMatches","hostSameGeneration","imageCaptured","contentMatches"].reduce(into:[String:String]()) { result,key in
        if details.isEmpty {result[key]="NOT_OBSERVED";return}
        let matches=details.filter{($0["checks"] as? [String:Bool])?[key]==true}.count
        result[key]=matches==0 ? "NO_SAMPLE" : matches==details.count ? "ALL_SAMPLES":"SOME_SAMPLES"
    }
    let crossed=fixtureEnd?["selectionAcrossService"] as? [String:Bool]
    let focusLost=signedHostTookFocus && crossed?["before"]==true && performed==true
    let retained=crossed?["before"]==true && crossed?["after"]==true && !unclearPostReturnSource && serviceReturn != nil
    report["sourceFocusRetention"]=focusLost ? "FAIL" : retained && confirmedSourceSample ? "PASS":"UNKNOWN"
    report["panelVisualContent"]=contentSeen ? "PASS":"UNKNOWN"
    report["captureAPICalls"]=samples.filter(\.captureAttempted).count
    report["visibleNonactivatingBubble"]="UNKNOWN"
    if ordered.contains("modelMissing") {report["translationCapability"]="BLOCKED_MODEL_MISSING"}
    guard performed == true, attempted == true else {
        report["status"]=attempted==true && performed==false ? "FAIL":"UNKNOWN"
        report["reason"]="Fixture did not positively confirm its single service dispatch";return report
    }
    if let sample=genericContentSample,let image=sample.image,
       let png=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) {
        try png.write(to:context.output.appendingPathComponent("generic-feedback.png"),options:.withoutOverwriting)
        report["genericFeedbackImage"]="generic-feedback.png"
    }
    if focusLost {
        report["status"]="FAIL";report["reason"]="The fixture lost its key document and the signed installed Host held foreground across a request-bound panel sample"
        return report
    }
    guard retained,let chosen=winner,let image=chosen.image,let request,
          let png=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])
    else {report["status"]="UNKNOWN";report["reason"]="No single live sample met every panel check; see panelSamples";return report}
    try png.write(to:context.output.appendingPathComponent("bubble.png"),options:.withoutOverwriting)
    let bubbleSurface=(chosen.number,chosen.rect)
    report["panelWindow"]=chosen.number;report["bubble"]=NSStringFromRect(chosen.rect)
    report["chosenSampleUptime"]=chosen.begin;report["panelContentSHA256"]=TranslationProof.digest(expected)
    report["fixtureFocusBefore"]=true;report["fixtureFocusAfter"]=true;report["visibleNonactivatingBubble"]="PASS"
    if language != .installed && words.isEmpty {
        report["missingLanguageNoticeObserved"]=true;report["status"]="BLOCKED"
        report["reason"]="Offline translation language resources are unavailable";return report
    }
    guard words.count==1,let word=words.first,word.language=="zh-Hans" else {
        report["status"]="FAIL";report["reason"]="The isolated wordbook has no unique translated row";return report
    }
    let plausible = report["expectedMeaning"] as? Bool == true
    report["bubbleMatchesStoredTranslation"] = true
    let orderedChain = TranslationProof.translated(evidence,source:phrase,answer:word.translation,id:request,pid:context.host.processIdentifier,window:bubbleSurface.0)
    report["orderedResultChain"]=orderedChain
    let stored = words[0]
    let linked = stored.requestID?.uuidString == stages["requestID"] as? String && stored.providerVersion != nil &&
        stored.sourceLanguage == source && stored.committedAt != nil && stored.sourceSHA256 == sourceDigest
    report["status"] = plausible && linked && orderedChain ? "PASS" : "FAIL"
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
