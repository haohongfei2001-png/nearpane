import AppKit
import CryptoKit

// Disposable ordinary document fixture. No product linkage, action API or focus shim.
let app = NSApplication.shared
guard CommandLine.arguments.count == 3, let expected = Int(CommandLine.arguments[2]), (1...2).contains(expected) else { exit(2) }
let run = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
var processInfo = proc_bsdinfo()
let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
guard proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &processInfo, infoSize) == infoSize, processInfo.pbi_start_tvsec > 0 else { exit(3) }
let birth = processInfo.pbi_start_tvsec * 1_000_000 + processInfo.pbi_start_tvusec
let session = run.lastPathComponent
guard UUID(uuidString: session) != nil else { exit(2) }
let policy = app.activationPolicy()
if policy != .regular { _ = app.setActivationPolicy(.regular) }
let presentation = ProcessInfo.processInfo.environment["NP_FIXTURE_PRESENTATION"]
#if P2_DOCUMENT_FIXTURE
if presentation == "p2-documents" { _ = umask(0o077) }
#endif
#if FIVE_PREVIEW
guard presentation == "five-preview", expected == 1,
      let fiveSlot = (0..<5).first(where: { Bundle.main.bundleIdentifier == FivePreviewWindow.identifier($0) }),
      let privateParent = PreviewFixtureDirectory(run),
      ["HOME", "CFFIXED_USER_HOME"].allSatisfy({ ProcessInfo.processInfo.environment[$0] == privateParent.appendingPathComponent("home").path })
else { exit(4) }
var fivePhase = 0
#else
guard ["net.example.spaces-document", "net.example.spaces-route-witness"].contains(Bundle.main.bundleIdentifier ?? "") else { exit(3) }
#endif
let startup: [String: Any] = ["bundle": Bundle.main.bundleIdentifier ?? "", "displayCount": NSScreen.screens.count,
                              "policy": app.activationPolicy().rawValue, "session": session, "pid": getpid(), "birth": birth]
try JSONSerialization.data(withJSONObject: startup).write(to: run.appendingPathComponent("startup.json"), options: .atomic)
guard app.activationPolicy() == .regular, NSScreen.screens.count == 1, let screen = NSScreen.screens.first else { exit(3) }
var windows = [NSWindow]()
var editors = [NSTextView]()
var lastState = Data()
var withdrew = false, minimized = false
NSWindow.allowsAutomaticWindowTabbing = false
#if P2_DOCUMENT_FIXTURE
let registeredDocuments = presentation == "p2-documents"
let p2LaunchHID = registeredDocuments ? p2Physical() : []
let p2FirstActivation=MainActor.assumeIsolated { P2FirstDocumentActivation() }
var documentFiles = [FieldDocumentFile]()
#else
let registeredDocuments = false
#endif
#if W01_MARKER_WITNESS
if expected == 2 && (presentation == nil || presentation == "ordinary" || registeredDocuments) {
    MainActor.assumeIsolated {
        FieldMarkerWitness.active = FieldMarkerWitness(folder:run,session:session,birth:birth) { (windows,editors) }
    }
}
#endif
#if PAIRED_PREVIEW
let paired = presentation == "paired-preview" && expected == 2 && Bundle.main.bundleIdentifier == "net.example.spaces-document"
if paired {
    let home=run.deletingLastPathComponent().appendingPathComponent("home").path
    guard ProcessInfo.processInfo.environment["HOME"]==home,ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]==home else {exit(4)}
}
let streaming=paired && ProcessInfo.processInfo.environment["NP_PAIRED_STREAM_FIXTURE"]=="1"
var previewStarted: TimeInterval?, previewEpoch = -1
@MainActor final class StreamPulse:NSObject {
    var phase=0
    @objc func draw(_ link:CADisplayLink) {
        guard editors.count==2,windows.allSatisfy({$0.isVisible}) else{return}
        phase ^= 1
        let epoch=max(0,previewEpoch)
        for (i,color) in PairedPreviewPalette.epochs[epoch].enumerated() {
            let rgb=color.map {min(255,max(0,$0+(phase==0 ? -5:5)))}
            editors[i].backgroundColor=NSColor(srgbRed:CGFloat(rgb[0])/255,green:CGFloat(rgb[1])/255,blue:CGFloat(rgb[2])/255,alpha:1)
            editors[i].needsDisplay=true
        }
    }
}
let pulse=MainActor.assumeIsolated{StreamPulse()}
var pulseLink:CADisplayLink?
#endif
final class SharedFixtureWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
@MainActor func addDocument(_ i: Int) {
        let frame = screen.visibleFrame
        let roster = presentation == "roster" || presentation == "roster-cycle" || presentation == "public-visible"
        let size: CGSize = roster ? (i == 0 ? CGSize(width: 540, height: 180) : CGSize(width: 240, height: 350)) : CGSize(width: 320, height: 160)
        var rect = NSRect(x: frame.midX - 180 + Double(30*i), y: frame.midY - 90 + Double(25*i), width: size.width, height: size.height)
        #if PAIRED_PREVIEW
        if paired { rect = NSRect(x: frame.midX + (i == 0 ? -282 : 12), y: frame.midY - 90, width: 270, height: 180) }
        #endif
        #if FIVE_PREVIEW
        rect = FivePreviewWindow.frame(slot: fiveSlot, in: frame)
        #endif
        let style: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
        let w: NSWindow
        if presentation == "public-visible" {
            let panel = SharedFixtureWindow(contentRect: rect, styleMask: style.union(.nonactivatingPanel), backing: .buffered, defer: false)
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
            panel.level = .normal
            w = panel
        } else {
            #if W01_MARKER_WITNESS
            if FieldMarkerWitness.active != nil { w=MarkerWitnessWindow(contentRect:rect,styleMask:style,backing:.buffered,defer:false) }
            else { w=NSWindow(contentRect:rect,styleMask:style,backing:.buffered,defer:false) }
            #else
            w = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
            #endif
        }
        w.title = i == 0 ? "Field Notes – A" : "Field Notes – B"
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        #if W01_MARKER_WITNESS
        let editor: NSTextView = FieldMarkerWitness.active == nil ? NSTextView(frame:w.contentView!.bounds) : MarkerWitnessEditor(frame:w.contentView!.bounds)
        #else
        let editor = NSTextView(frame: w.contentView!.bounds)
        #endif
        #if FIVE_PREVIEW
        w.title = "Field Notes " + String(fiveSlot + 1)
        w.colorSpace = .sRGB
        editor.backgroundColor = FivePreviewWindow.color(slot: fiveSlot, phase: 0)
        #endif
        #if P2_DOCUMENT_FIXTURE
        if registeredDocuments {
            guard let file=FieldDocumentFile(folder:run,slot:i,session:session) else { exit(5) }
            let name = i == 0 ? "A" : "B"
            w.representedURL=file.url
            w.setAccessibilityDocument(file.url.absoluteString)
            w.setAccessibilityIdentifier("p2-document-window-"+name)
            editor.setAccessibilityIdentifier("p2-document-editor-"+name)
            editor.string=file.seed
            editor.setSelectedRange(NSRange(location:file.seed.utf16.count,length:0))
            documentFiles.append(file); editor.delegate=file
        }
        #endif
        if roster { editor.backgroundColor = i == 0 ? NSColor.systemGreen : NSColor.systemPurple }
        editor.autoresizingMask = [.width,.height]
        editor.font = .systemFont(ofSize: 16)
        w.contentView = editor
        w.initialFirstResponder = editor
        _ = w.makeFirstResponder(editor)
        windows.append(w); editors.append(editor)
        if presentation == "contract" || presentation == "contract-split" || presentation == "roster-cycle" || presentation == "five-preview" {
            w.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps:true)
        } else { w.orderFrontRegardless() }
}
DispatchQueue.main.asyncAfter(deadline:.now()+0.3) {
    for i in 0..<(presentation == "contract-split" ? 1 : expected) { addDocument(i) }
    #if PAIRED_PREVIEW
    if streaming,windows.count==2 {
        for w in windows {w.colorSpace = .sRGB}
        let link=editors[0].displayLink(target:pulse,selector:#selector(StreamPulse.draw(_:)))
        link.preferredFrameRateRange=CAFrameRateRange(minimum:30,maximum:60,preferred:60)
        link.add(to:.main,forMode:.common);pulseLink=link
    }
    if paired,windows.count==2 {
        // These two owned documents have just opened on the preverified empty lease. Normal
        // AppKit activation publishes a real key/standard AX window for the production roster.
        if streaming {
            app.activate(ignoringOtherApps:true)
            windows[1].orderFront(nil)
            windows[0].makeKeyAndOrderFront(nil)
        } else {
            windows[0].makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps:true)
        }
    }
    #endif
}
let start = ProcessInfo.processInfo.systemUptime
let timer = Timer(timeInterval: 0.045, repeats: true) { _ in
    let inactiveCleanup = registeredDocuments && FileManager.default.fileExists(atPath:run.appendingPathComponent("close-when-inactive").path)
    let closing = inactiveCleanup || FileManager.default.fileExists(atPath:run.appendingPathComponent("close").path) ||
        ProcessInfo.processInfo.systemUptime - start > (presentation?.hasPrefix("contract") == true ? 900 : (presentation=="paired-preview" ? 240 : 150))
    var yieldToUser = inactiveCleanup
    #if P2_DOCUMENT_FIXTURE
    if registeredDocuments && !closing { MainActor.assumeIsolated { p2FirstActivation.tick(folder:run,birth:birth,windows:windows) } }
    if closing && registeredDocuments && (p2Physical() != p2LaunchHID || NSEvent.pressedMouseButtons != 0) {
        yieldToUser=true
        let flag=run.appendingPathComponent("p2-user-superseded")
        if !FileManager.default.fileExists(atPath:flag.path) { _=FileManager.default.createFile(atPath:flag.path,contents:Data(),attributes:[.posixPermissions:0o600]) }
    }
    #endif
    if closing && (!yieldToUser || (!app.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid())) {
        #if W01_MARKER_WITNESS
        MainActor.assumeIsolated { FieldMarkerWitness.active?.tick(final:true) }
        #endif
        for w in windows { w.orderOut(nil); w.close() }
        app.terminate(nil); return
    }
    if presentation == "contract-split", windows.count==1, expected==2,
       FileManager.default.fileExists(atPath:run.appendingPathComponent("open-second").path) { MainActor.assumeIsolated { addDocument(1) } }
    if presentation == "roster-cycle" {
        if !windows.isEmpty, (try? FileManager.default.removeItem(at: run.appendingPathComponent("close-documents"))) != nil {
            for window in windows { window.close() }
            windows.removeAll()
            editors.removeAll()
        }
        if windows.isEmpty, (try? FileManager.default.removeItem(at: run.appendingPathComponent("open-documents"))) != nil {
            MainActor.assumeIsolated { for index in 0..<expected { addDocument(index) } }
        }
    }
    guard !windows.isEmpty || presentation == "roster-cycle" else { return }
    #if W01_MARKER_WITNESS
    MainActor.assumeIsolated { FieldMarkerWitness.active?.tick() }
    #endif
    #if FIVE_PREVIEW
    if fivePhase == 0, let window = windows.first, let editor = editors.first,
       let data = try? Data(contentsOf: run.appendingPathComponent("advance.json")),
       let mark = try? JSONDecoder().decode(FivePreviewMarker.self, from: data),
       mark.matches(session: session, pid: getpid(), birth: birth, number: window.windowNumber, slot: fiveSlot) {
        fivePhase = 1
        editor.backgroundColor = FivePreviewWindow.color(slot: fiveSlot, phase: 1)
        editor.needsDisplay = true
    }
    #endif
    #if PAIRED_PREVIEW
    if paired && editors.count == 2 {
        let now = ProcessInfo.processInfo.systemUptime
        if previewStarted == nil && FileManager.default.fileExists(atPath: run.appendingPathComponent("preview-start").path) { previewStarted = now }
        var epoch = previewStarted.map { min(PairedPreviewPalette.epochs.count-1, 1+Int((now-$0)/(streaming ? 3.6:PairedPreviewPalette.seconds))) } ?? 0
        // An optional post-measurement film changes only these two enrolled
        // synthetic documents. The command expires even if its reader exits.
        if streaming,previewStarted != nil,ProcessInfo.processInfo.environment["NP_PAIRED_CARD_FILM"]=="1",
           let file=try? Data(contentsOf:run.appendingPathComponent("film-marker.json")),
           let mark=try? JSONDecoder().decode(PairedFilmMarker.self,from:file),
           mark.admits(session:session,pid:getpid(),birth:birth,numbers:windows.map(\.windowNumber),now:now) {
            epoch=mark.epoch
        }
        if epoch != previewEpoch {
            for (index, rgb) in PairedPreviewPalette.epochs[epoch].enumerated() where !streaming {
                editors[index].backgroundColor = NSColor(srgbRed: CGFloat(rgb[0])/255, green: CGFloat(rgb[1])/255,
                                                         blue: CGFloat(rgb[2])/255, alpha: 1)
                editors[index].needsDisplay = true
            }
            previewEpoch = epoch
        }
    }
    #endif
    if presentation == "contract", windows.count == 2, windows.filter({ !$0.isVisible }).count == 1 {
        let recreate = run.appendingPathComponent("recreate-closed")
        if (try? FileManager.default.removeItem(at:recreate)) != nil {
            MainActor.assumeIsolated { addDocument(2) }
        }
    }
    if presentation?.hasPrefix("contract") == true {
        let activation = run.appendingPathComponent("activate-first")
        if (try? FileManager.default.removeItem(at:activation)) != nil {
            app.activate(ignoringOtherApps:true)
            windows[0].makeKeyAndOrderFront(nil)
        }
    }
    if presentation == "roster", windows.count == 2 {
        if !withdrew, FileManager.default.fileExists(atPath: run.appendingPathComponent("withdraw-first").path) {
            withdrew = true
            windows[0].orderOut(nil)
        }
        if !minimized, FileManager.default.fileExists(atPath: run.appendingPathComponent("minimize-second").path) {
            minimized = true
            windows[1].miniaturize(nil)
        }
    }
    var payload: [String: Any] = [
        "session": session, "pid": getpid(), "birth": birth, "numbers": windows.map { $0.windowNumber },
        "presentation": presentation ?? "ordinary", "bundle": Bundle.main.bundleIdentifier ?? "",
        "visible": windows.map(\.isVisible), "minimized": windows.map(\.isMiniaturized),
        "sizes": windows.map { [$0.frame.width, $0.frame.height] },
        "key": app.keyWindow?.windowNumber ?? 0, "main": app.mainWindow?.windowNumber ?? 0,
        "editorsFocused": zip(windows, editors).map { $0.firstResponder === $1 },
        "sha256": editors.map { SHA256.hash(data: Data($0.string.utf8)).map { String(format: "%02x", $0) }.joined() }
    ]
    #if P2_DOCUMENT_FIXTURE
    if registeredDocuments { payload["filesSaved"] = MainActor.assumeIsolated { documentFiles.map { $0.saved } } }
    #endif
    #if FIVE_PREVIEW
    payload["slot"] = fiveSlot
    payload["phase"] = fivePhase
    #endif
    if let data = try? JSONSerialization.data(withJSONObject: payload, options: .sortedKeys), data != lastState {
        try? data.write(to: run.appendingPathComponent("windows.json"), options: .atomic); lastState = data
    }
}
RunLoop.main.add(timer, forMode: .common)
app.run()
