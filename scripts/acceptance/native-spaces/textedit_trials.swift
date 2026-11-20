// Included with the installed-sidebar observer by build-contract.sh. Only the two
// enrolled synthetic file URLs may be inspected in a fresh system TextEdit process.
import CryptoKit

struct DocumentRefusal: Error { let reason: String; init(_ reason: String) { self.reason = reason } }
struct DocumentRequest: Decodable {
    let mode: String, folder: String, display: String, space: UInt64, hostPID: Int32, hostHash: String
    let index: Int?, marker: String?, hid: [UInt32]
}
struct DocumentInstance: Codable {
    let pid: Int32, birth: UInt64, launch: TimeInterval, hash: String
    let consoleUID: uid_t?
}
func textInputCounters() -> [UInt32] {
    [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel].map {
        CGEventSource.counterForEventType(.hidSystemState, eventType:$0)
    }
}
func physicalDocumentPath(_ path: String) -> String? {
    guard let resolved=realpath(path,nil) else {return nil}
    defer {free(resolved)}
    return String(cString:resolved)
}
func ownedDocumentNode(_ path: String, directory: Bool) -> Bool {
    var info=stat()
    guard lstat(path,&info)==0,info.st_uid==getuid(),info.st_mode & 0o077 == 0 else {return false}
    return info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) && (directory || info.st_nlink==1)
}
func textDocuments(_ request: DocumentRequest) throws -> Object {
    let folder = URL(fileURLWithPath:request.folder, isDirectory:true)
    let kit = folder.deletingLastPathComponent()
    let manager = FileManager.default
    let appURL = TextEditProcessIdentity.application
    let wanted = ["A.txt", "B.txt"].map { folder.appendingPathComponent($0) }
    let receiptURL = folder.appendingPathComponent("instance.json")
    guard UUID(uuidString:folder.lastPathComponent) != nil, let rootPath=physicalDocumentPath("/private/tmp"),
          physicalDocumentPath(kit.deletingLastPathComponent().path)==rootPath,kit.lastPathComponent.hasPrefix("nearpane-d01."),
          physicalDocumentPath(folder.path)==rootPath+"/"+kit.lastPathComponent+"/"+folder.lastPathComponent,
          ownedDocumentNode(kit.path,directory:true),ownedDocumentNode(folder.path,directory:true),
          wanted.allSatisfy({ownedDocumentNode($0.path,directory:false)}) else {throw DocumentRefusal("directory, owner or file mode differs from private test enrollment")}
    guard AXIsProcessTrusted() else {throw DocumentRefusal("test observer does not have Accessibility")}
    guard NPReadOnlySpacesOpen()==1 else {throw DocumentRefusal("system Space readback unavailable")}
    func guardInput() throws {
        let active = inventory()?.first { $0["scope"] as? String == request.display }
        guard let host, host.processIdentifier == request.hostPID, runningCodeHash(host.processIdentifier) == request.hostHash,
              active?["current"] as? UInt64 == request.space,
              (active?["records"] as? [Object])?.contains(where: { $0["id"] as? UInt64 == request.space && $0["type"] as? Int == 0 }) == true,
              textInputCounters()==request.hid, NSEvent.pressedMouseButtons==0
        else { throw DocumentRefusal("test Space, user input or installed Host identity changed") }
    }
    func instance(_ application: NSRunningApplication) throws -> DocumentInstance {
        guard application.bundleURL?.standardizedFileURL.path == appURL.path,
              application.bundleIdentifier=="com.apple.TextEdit", !application.isTerminated,
              let launch=application.launchDate?.timeIntervalSince1970, let live=TextEditProcessIdentity.read(application.processIdentifier)
        else { throw DocumentRefusal("could not verify Apple TextEdit at its system path") }
        return DocumentInstance(pid:live.pid, birth:live.birth, launch:launch, hash:live.hash, consoleUID:live.uid)
    }
    if request.mode == "open" {
        try guardInput()
        guard !manager.fileExists(atPath:receiptURL.path), NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.TextEdit").isEmpty,
              wanted.allSatisfy({ (try? Data(contentsOf:$0)) == Data() })
        else { throw DocumentRefusal("TextEdit is already in use or test inputs are not fresh") }
        let home=folder.appendingPathComponent("home",isDirectory:true)
        try manager.createDirectory(at:home,withIntermediateDirectories:false)
        let config=NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance=true
        config.activates=true
        config.addsToRecentItems=false
        config.promptsUserIfNeeded=false
        config.environment=["HOME":home.path,"CFFIXED_USER_HOME":home.path]
        config.arguments=["-ApplePersistenceIgnoreState","YES","-NSQuitAlwaysKeepsWindows","NO","-AppleWindowTabbingMode","manual"]
        var reply: Result<DocumentInstance,Error>?
        NSWorkspace.shared.open(wanted,withApplicationAt:appURL,configuration:config) { app,error in
            do {
                if let error { throw error }
                guard let app else { throw DocumentRefusal("Launch Services did not identify the new application") }
                let record=try instance(app)
                try JSONEncoder().encode(record).write(to:receiptURL,options:.withoutOverwriting)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)
                reply = .success(record)
            } catch { reply = .failure(error) }
        }
        let stop=Date().addingTimeInterval(8)
        while reply==nil, Date()<stop { RunLoop.current.run(until:Date().addingTimeInterval(0.03)) }
        guard let record=try reply?.get() else { throw DocumentRefusal("TextEdit launch receipt is unknown") }
        return ["pid":record.pid,"birth":record.birth,"launch":record.launch,"hash":record.hash,
                "consoleUID":getuid(),"identityWitness":"console kernel generation and Apple-signed system executable CDHash"]
    }
    guard ownedDocumentNode(receiptURL.path,directory:false) else {throw DocumentRefusal("owned TextEdit enrollment is unavailable")}
    let enrolled=try JSONDecoder().decode(DocumentInstance.self,from:Data(contentsOf:receiptURL))
    guard let live=TextEditProcessIdentity.read(enrolled.pid),live.birth==enrolled.birth,live.hash==enrolled.hash,
          enrolled.consoleUID.map({ $0==live.uid }) ?? true else {
        throw DocumentRefusal("kernel generation, console owner or signed system TextEdit executable changed or is unavailable")
    }
    let root=AXUIElementCreateApplication(enrolled.pid)
    _=AXUIElementSetMessagingTimeout(root,0.5)
    func owner(_ element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element,&pid) == .success ? pid : nil
    }
    func element(_ source: AXUIElement, _ key: String) -> AXUIElement? {
        guard let raw=value(source,key),CFGetTypeID(raw)==AXUIElementGetTypeID() else {return nil}
        return (raw as! AXUIElement)
    }
    func boundWindows() throws -> [AXUIElement] {
        guard wanted.allSatisfy({ ownedDocumentNode($0.path,directory:false) }) else {throw DocumentRefusal("synthetic file ownership changed")}
        guard let windows=value(root,kAXWindowsAttribute) as? [AXUIElement], windows.count==2 else {
            throw DocumentRefusal("TextEdit has not exposed exactly the two enrolled document windows")
        }
        let paths=wanted.compactMap {physicalDocumentPath($0.path)}
        guard paths.count==2,Set(paths).count==2 else {throw DocumentRefusal("synthetic files disappeared")}
        var result=[String:AXUIElement]()
        for window in windows {
            guard owner(window)==enrolled.pid,let raw=value(window,kAXDocumentAttribute) as? String, let url=URL(string:raw),url.isFileURL,
                  (url.host ?? "").isEmpty || url.host=="localhost",
                  let path=physicalDocumentPath(url.path), paths.contains(path), result[path]==nil else {throw DocumentRefusal("a window is not bound to the disposable document URLs")}
            result[path]=window
        }
        return try paths.map { guard let w=result[$0] else {throw DocumentRefusal("test document missing")}; return w }
    }
    if request.mode != "close" {try guardInput()}
    let windows=try boundWindows()
    if request.mode=="close" {
        // A new user document in our process revokes permission to terminate it.
        guard let app=NSRunningApplication(processIdentifier:enrolled.pid),try instance(app).launch==enrolled.launch,
              textInputCounters()==request.hid,TextEditProcessIdentity.kernelBirth(enrolled.pid)==enrolled.birth,
              app.terminate() else {throw DocumentRefusal("could not quit the owned TextEdit instance")}
        return ["quitRequested":true,"pid":enrolled.pid]
    }
    let numbers=windows.map { NPReadAXWindowNumber($0) }
    guard Set(numbers).count==2, !numbers.contains(0),
          numbers.allSatisfy({ NPReadWindowSpaces($0) as? [UInt64] == [request.space] }) else { throw DocumentRefusal("document number or system membership unavailable") }
    func editor(_ window: AXUIElement) throws -> AXUIElement {
        var queue=[window], found=[AXUIElement](), seen=0
        while let e=queue.popLast(),seen<120 {
            seen += 1
            guard owner(e)==enrolled.pid else {throw DocumentRefusal("editor hierarchy changed owner")}
            if value(e,kAXRoleAttribute) as? String == kAXTextAreaRole { found.append(e);continue }
            queue += value(e,kAXChildrenAttribute) as? [AXUIElement] ?? []
        }
        guard queue.isEmpty, found.count==1 else {throw DocumentRefusal("owned TextEdit document has no unique editor")}
        return found[0]
    }
    let editors=try windows.map(editor)
    let system=AXUIElementCreateSystemWide()
    _=AXUIElementSetMessagingTimeout(system,0.5)
    let focusReader=TextEditFocusReader(read:element,owner:owner,same:{ CFEqual($0,$1) })
    func focus(editor: AXUIElement? = nil) throws -> (focused: Int, main: Int?) {
        guard let result=focusReader.indices(system:system,root:root,pid:enrolled.pid,windows:windows,editor:editor) else {
            throw DocumentRefusal("system Accessibility could not confirm the enrolled focused application, window or editor")
        }
        return result
    }
    func verifyWindows() throws {
        let current=try boundWindows()
        guard zip(current,windows).allSatisfy({ CFEqual($0,$1) }),current.map({ NPReadAXWindowNumber($0) })==numbers,
              numbers.allSatisfy({ NPReadWindowSpaces($0) as? [UInt64] == [request.space] }) else {
            throw DocumentRefusal("enrolled document windows or Space changed")
        }
    }
    func guardBoundary() throws {
        guard TextEditProcessIdentity.kernelBirth(enrolled.pid)==enrolled.birth,
              textInputCounters()==request.hid,NSEvent.pressedMouseButtons==0 else {
            throw DocumentRefusal("console owner, process generation or physical input changed during the focus proof")
        }
    }
    let initial=try focus()
    if request.mode=="sample" {
        let strings=try editors.map { e -> String in
            guard let str=value(e,kAXValueAttribute) as? String,str.utf8.count<=4096 else {throw DocumentRefusal("bounded test editor unavailable")}
            return str
        }
        let hashes=strings.map { SHA256.hash(data:Data($0.utf8)).map { String(format:"%02x",$0) }.joined() }
        let marker=request.marker ?? ""
        try guardInput()
        try verifyWindows()
        let final=try focus()
        guard initial.focused==final.focused,initial.main==final.main else {throw DocumentRefusal("system focus changed during readback")}
        try guardBoundary()
        return ["numbers":numbers,"focused":numbers[final.focused],"main":final.main.map { numbers[$0] } ?? 0,"front":true,
                "focusWitness":"systemAX","pid":enrolled.pid,"hashes":hashes,
                "markerCounts":strings.map { marker.isEmpty ? 0 : $0.components(separatedBy:marker).count-1 }]
    }
    guard let i=request.index, (0..<2).contains(i), let host else {
        throw DocumentRefusal("test document lost foreground ownership")
    }
    if request.mode=="press" {
        let id="current-desktop-window:\(enrolled.pid):\(numbers[i])"
        let sidebar=Sidebar(host,rows:rows)
        guard let exact=sidebar.controls[id],exact.count==1,value(exact[0],kAXEnabledAttribute) as? Bool == true else {
            throw DocumentRefusal("installed sidebar has no unique enabled document control")
        }
        try guardInput()
        try verifyWindows()
        guard owner(exact[0])==host.processIdentifier,value(exact[0],kAXIdentifierAttribute) as? String==id,
              value(exact[0],kAXEnabledAttribute) as? Bool==true,try focus().focused==initial.focused else {
            throw DocumentRefusal("sidebar control or focused document changed before press")
        }
        try guardBoundary()
        let error=AXUIElementPerformAction(exact[0],kAXPressAction as CFString)
        return ["issued":true,"axError":error.rawValue,"control":id,"focusWitness":"systemAX"]
    }
    guard request.mode=="marker", let marker=request.marker,marker.utf8.count==12,marker.hasPrefix("NP"),marker.dropFirst(2).allSatisfy(\.isHexDigit),
          initial.focused==i,initial.main==i,
          CGPreflightPostEventAccess(),let source=CGEventSource(stateID:.privateState),
          let down=CGEvent(keyboardEventSource:source,virtualKey:0,keyDown:true),let up=CGEvent(keyboardEventSource:source,virtualKey:0,keyDown:false)
    else { throw DocumentRefusal("target is not the key, main, focused synthetic editor") }
    let units=Array(marker.utf16)
    for event in [down,up] { event.flags=[];event.keyboardSetUnicodeString(stringLength:units.count,unicodeString:units) }
    try guardInput()
    try verifyWindows()
    guard CFEqual(try editor(windows[i]),editors[i]),try focus(editor:editors[i]).focused==i else {
        throw DocumentRefusal("target editor lost system keyboard focus before marker")
    }
    try guardBoundary()
    down.postToPid(enrolled.pid);up.postToPid(enrolled.pid)
    return ["issued":true,"number":numbers[i],"focusWitness":"systemAX"]
}

do {
    let request=try JSONDecoder().decode(DocumentRequest.self,from:FileHandle.standardInput.readDataToEndOfFile())
    let result=try textDocuments(request)
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:result)+Data([10]))
} catch {
    // Only our explicit guards prove that this invocation stopped before AXPress.
    let refusal = error as? DocumentRefusal
    let reply: Object = ["issued": refusal == nil ? NSNull() as Any : false,
                         "reason": refusal?.reason ?? "system document helper did not produce a confirmed reply"]
    FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject:reply)+Data([10]));exit(2)
}
