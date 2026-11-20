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
    let appURL = URL(fileURLWithPath:"/System/Applications/TextEdit.app", isDirectory:true)
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
              let launch=application.launchDate?.timeIntervalSince1970, let hash=runningCodeHash(application.processIdentifier),
              let birth=birthMicroseconds(application.processIdentifier)
        else { throw DocumentRefusal("could not verify Apple TextEdit at its system path") }
        return DocumentInstance(pid:application.processIdentifier, birth:birth, launch:launch, hash:hash)
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
        return ["pid":record.pid,"birth":record.birth,"launch":record.launch,"hash":record.hash]
    }
    let enrolled=try JSONDecoder().decode(DocumentInstance.self,from:Data(contentsOf:receiptURL))
    guard let app=NSRunningApplication(processIdentifier:enrolled.pid) else {
        throw DocumentRefusal("enrolled TextEdit is not registered with Launch Services")
    }
    let live=try instance(app)
    guard live.birth == enrolled.birth && live.launch==enrolled.launch && live.hash==enrolled.hash else { throw DocumentRefusal("TextEdit process generation changed") }
    let root=AXUIElementCreateApplication(enrolled.pid)
    _=AXUIElementSetMessagingTimeout(root,0.5)
    func boundWindows() throws -> [AXUIElement] {
        guard let windows=value(root,kAXWindowsAttribute) as? [AXUIElement], windows.count==2 else {
            throw DocumentRefusal("TextEdit has not exposed exactly the two enrolled document windows")
        }
        let paths=wanted.compactMap {physicalDocumentPath($0.path)}
        guard paths.count==2,Set(paths).count==2 else {throw DocumentRefusal("synthetic files disappeared")}
        var result=[String:AXUIElement]()
        for window in windows {
            guard let raw=value(window,kAXDocumentAttribute) as? String, let url=URL(string:raw),url.isFileURL,
                  let path=physicalDocumentPath(url.path), paths.contains(path), result[path]==nil else {throw DocumentRefusal("a window is not bound to the disposable document URLs")}
            result[path]=window
        }
        return try paths.map { guard let w=result[$0] else {throw DocumentRefusal("test document missing")}; return w }
    }
    let windows=try boundWindows()
    if request.mode=="close" {
        // A new user document in our process revokes permission to terminate it.
        guard textInputCounters()==request.hid, birthMicroseconds(enrolled.pid)==enrolled.birth,
              app.terminate() else {throw DocumentRefusal("could not quit the owned TextEdit instance")}
        return ["quitRequested":true,"pid":enrolled.pid]
    }
    try guardInput()
    let numbers=windows.map { NPReadAXWindowNumber($0) }
    guard Set(numbers).count==2, !numbers.contains(0),
          numbers.allSatisfy({ NPReadWindowSpaces($0) as? [UInt64] == [request.space] }) else { throw DocumentRefusal("document number or system membership unavailable") }
    func editor(_ window: AXUIElement) throws -> AXUIElement {
        var queue=[window], found=[AXUIElement](), seen=0
        while let e=queue.popLast(),seen<120 {
            seen += 1
            if value(e,kAXRoleAttribute) as? String == kAXTextAreaRole { found.append(e);continue }
            queue += value(e,kAXChildrenAttribute) as? [AXUIElement] ?? []
        }
        guard queue.isEmpty, found.count==1 else {throw DocumentRefusal("owned TextEdit document has no unique editor")}
        return found[0]
    }
    let editors=try windows.map(editor)
    let focused=focusedNumber(enrolled.pid) ?? 0
    let main: UInt32 = value(root,kAXMainWindowAttribute).map { NPReadAXWindowNumber($0) } ?? 0
    if request.mode=="sample" {
        let strings=try editors.map { e -> String in
            guard let str=value(e,kAXValueAttribute) as? String,str.utf8.count<=4096 else {throw DocumentRefusal("bounded test editor unavailable")}
            return str
        }
        let hashes=strings.map { SHA256.hash(data:Data($0.utf8)).map { String(format:"%02x",$0) }.joined() }
        let marker=request.marker ?? ""
        return ["numbers":numbers,"focused":focused,"main":main,"front":app.isActive,"pid":enrolled.pid,"hashes":hashes,
                "markerCounts":strings.map { marker.isEmpty ? 0 : $0.components(separatedBy:marker).count-1 }]
    }
    guard let i=request.index, (0..<2).contains(i), app.isActive, numbers.contains(focused), let host else {
        throw DocumentRefusal("test document lost foreground ownership")
    }
    if request.mode=="press" {
        let id="current-desktop-window:\(enrolled.pid):\(numbers[i])"
        let sidebar=Sidebar(host,rows:rows)
        guard let exact=sidebar.controls[id],exact.count==1,value(exact[0],kAXEnabledAttribute) as? Bool == true else {
            throw DocumentRefusal("installed sidebar has no unique enabled document control")
        }
        try guardInput()
        let error=AXUIElementPerformAction(exact[0],kAXPressAction as CFString)
        return ["issued":true,"axError":error.rawValue,"control":id]
    }
    guard request.mode=="marker", let marker=request.marker,marker.utf8.count==12,marker.hasPrefix("NP"),marker.dropFirst(2).allSatisfy(\.isHexDigit),
          focused==numbers[i],main==numbers[i],let focus=value(root,kAXFocusedUIElementAttribute),CFEqual(focus,editors[i]),
          CGPreflightPostEventAccess(),let source=CGEventSource(stateID:.privateState),
          let down=CGEvent(keyboardEventSource:source,virtualKey:0,keyDown:true),let up=CGEvent(keyboardEventSource:source,virtualKey:0,keyDown:false)
    else { throw DocumentRefusal("target is not the key, main, focused synthetic editor") }
    let units=Array(marker.utf16)
    for event in [down,up] { event.flags=[];event.keyboardSetUnicodeString(stringLength:units.count,unicodeString:units) }
    try guardInput()
    down.postToPid(enrolled.pid);up.postToPid(enrolled.pid)
    return ["issued":true,"number":numbers[i]]
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
