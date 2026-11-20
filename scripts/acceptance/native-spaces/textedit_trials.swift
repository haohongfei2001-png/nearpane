// Included with the installed-sidebar observer by build-contract.sh. Only the two
// enrolled synthetic file URLs may be inspected in a fresh system TextEdit process.
import CryptoKit

struct DocumentRefusal: Error { let reason: String; init(_ reason: String) { self.reason = reason } }
struct DocumentRequest: Decodable {
    let mode: String, folder: String, display: String, space: UInt64, hostPID: Int32, hostHash: String
    let hostBirth: UInt64, index: Int?, target: UInt32?, numbers: [UInt32]?, panel: UInt32?, marker: String?, hid: [UInt32]
}
struct DocumentInstance: Codable {
    let pid: Int32, birth: UInt64, launch: TimeInterval?, hash: String
    let consoleUID: uid_t?
    let architecture: TextEditArchitecture?
}
struct DocumentWindowPair: Codable, Equatable { let pid: pid_t, birth: UInt64, numbers: [UInt32] }
struct DocumentLaunchIntent: Codable { let notBefore: UInt64 }
struct DocumentLaunchCandidate: Codable { let pid: pid_t, birth: UInt64?, notBefore: UInt64, callbackTime: UInt64 }
func launchClock() throws -> UInt64 {
    var clock=timeval()
    guard gettimeofday(&clock,nil)==0,clock.tv_sec>0 else {throw TextEditIdentityRefusal("launchClock","kernel wall clock unavailable")}
    return UInt64(clock.tv_sec)*1_000_000+UInt64(clock.tv_usec)
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
// The product card is queried by its opaque AX identifier. No window labels are exported.
func documentControl(_ host: NSRunningApplication, id: String, display: String) -> (AXUIElement?, Object) {
    let hostRows = rows.filter { $0[kCGWindowOwnerPID as String] as? pid_t == host.processIdentifier &&
        $0[kCGWindowIsOnscreen as String] as? Bool == true }
    let index = Sidebar(host, rows: hostRows)
    let matches = index.controls[id] ?? []
    var note: Object = ["matches": matches.count, "regions": index.areas]
    func stop(_ state: String) -> (AXUIElement?, Object) { note["state"] = state; return (nil, note) }
    if let state = TextEditSidebarButtonRead.matchState(count:matches.count,rosterCount:index.areas) { return stop(state) }
    let node = matches[0]
    func owned(_ element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        return AXUIElementGetPid(element,&pid) == .success && pid == host.processIdentifier
    }
    guard owned(node), value(node,kAXIdentifierAttribute) as? String == id else { return stop("identityChanged") }
    let role = value(node,kAXRoleAttribute) as? String
    note["button"] = role == kAXButtonRole
    guard role == kAXButtonRole else { return stop("buttonUnavailable") }
    var raw: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(node,kAXEnabledAttribute as CFString,&raw)
    note["enabledAXError"] = error.rawValue
    guard let enabled = TextEditSidebarButtonRead.enabled(status:error,value:raw) else { return stop("enabledUnreadable") }
    note["enabled"] = enabled
    guard enabled else { return stop("disabled") }
    var names: CFArray?
    let actionError = AXUIElementCopyActionNames(node,&names)
    note["actionsAXError"] = actionError.rawValue
    guard actionError == .success, (names as? [String])?.contains(kAXPressAction) == true else { return stop("pressActionUnavailable") }
    func rect(_ element: AXUIElement) -> CGRect? {
        guard let p = value(element,kAXPositionAttribute), let s = value(element,kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue,.cgPoint,&origin), AXValueGetValue(s as! AXValue,.cgSize,&size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin:origin,size:size)
    }
    guard index.regions.count == 1, owned(index.regions[0]), let region = rect(index.regions[0]), let card = rect(node) else { return stop("rosterGeometryUnavailable") }
    let center = CGPoint(x:card.midX,y:card.midY)
    guard region.contains(center) else { return stop("cardOutsideRoster") }
    func axElement(_ raw: CFTypeRef?) -> AXUIElement? {
        guard let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }
    var ancestor = axElement(value(node,kAXWindowAttribute)) ?? node
    for _ in 0..<36 {
        guard owned(ancestor) else { return stop("panelUnverified") }
        if value(ancestor,kAXRoleAttribute) as? String == kAXWindowRole { break }
        guard let parent = axElement(value(ancestor,kAXParentAttribute)) else { return stop("panelUnverified") }
        ancestor = parent
    }
    let panel = NPReadAXWindowNumber(ancestor)
    guard panel > 0, owned(ancestor), value(ancestor,kAXRoleAttribute) as? String == kAXWindowRole,
          hostRows.contains(where: { row in
              guard row[kCGWindowNumber as String] as? UInt32 == panel,
                    row[kCGWindowLayer as String] as? Int == Int(CGWindowLevelForKey(.floatingWindow)),
                    let raw = row[kCGWindowBounds as String] as? NSDictionary else { return false }
              return CGRect(dictionaryRepresentation:raw)?.contains(center) == true
          }) else { return stop("panelUnverified") }
    let screens = displays().filter { screen in
        display == "Main" ? screen["main"] as? Bool == true : (screen["uuid"] as? String)?.caseInsensitiveCompare(display) == .orderedSame
    }
    guard screens.count == 1, let frame = screens[0]["bounds"] as? [CGFloat], frame.count == 4,
          CGRect(x:frame[0],y:frame[1],width:frame[2],height:frame[3]).contains(center) else { return stop("wrongDisplay") }
    note["panel"] = panel
    note["state"] = "ready"
    return (node, note)
}

func textDocuments(_ request: DocumentRequest, reads: inout [Object], controlRead: inout Object?) throws -> Object {
    let folder = URL(fileURLWithPath:request.folder, isDirectory:true)
    let kit = folder.deletingLastPathComponent()
    let manager = FileManager.default
    let appURL = TextEditProcessIdentity.application
    let wanted = ["A.txt", "B.txt"].map { folder.appendingPathComponent($0) }
    let receiptURL = folder.appendingPathComponent("instance.json")
    let intentURL = folder.appendingPathComponent("launch-intent.json")
    let candidateURL = folder.appendingPathComponent("launch-callback.json")
    guard UUID(uuidString:folder.lastPathComponent) != nil, let rootPath=physicalDocumentPath("/private/tmp"),
          physicalDocumentPath(kit.deletingLastPathComponent().path)==rootPath,kit.lastPathComponent.hasPrefix("nearpane-d01."),
          physicalDocumentPath(folder.path)==rootPath+"/"+kit.lastPathComponent+"/"+folder.lastPathComponent,
          ownedDocumentNode(kit.path,directory:true),ownedDocumentNode(folder.path,directory:true),
          wanted.allSatisfy({ownedDocumentNode($0.path,directory:false)}) else {throw DocumentRefusal("directory, owner or file mode differs from private test enrollment")}
    guard AXIsProcessTrusted() else {throw DocumentRefusal("test observer does not have Accessibility")}
    guard NPReadOnlySpacesOpen()==1 else {throw DocumentRefusal("system Space readback unavailable")}
    func guardInput() throws {
        let active = inventory()?.first { $0["scope"] as? String == request.display }
        guard let host, !host.isTerminated, host.processIdentifier == request.hostPID,
              birthMicroseconds(host.processIdentifier) == request.hostBirth, runningCodeHash(host.processIdentifier) == request.hostHash,
              active?["current"] as? UInt64 == request.space,
              (active?["records"] as? [Object])?.contains(where: { $0["id"] as? UInt64 == request.space && $0["type"] as? Int == 0 }) == true,
              textInputCounters()==request.hid, NSEvent.pressedMouseButtons==0
        else { throw DocumentRefusal("test Space, user input or installed Host identity changed") }
    }
    func save<T: Encodable>(_ record: T, to url: URL) throws {
        try JSONEncoder().encode(record).write(to:url,options:.withoutOverwriting)
        try manager.setAttributes([.posixPermissions: 0o600],ofItemAtPath:url.path)
    }
    func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        guard ownedDocumentNode(url.path,directory:false) else {throw DocumentRefusal("private TextEdit enrollment record unavailable")}
        return try JSONDecoder().decode(type,from:Data(contentsOf:url))
    }
    func enroll(_ candidate: DocumentLaunchCandidate, application: NSRunningApplication?, fromCallback: Bool = false) throws -> DocumentInstance {
        let intent = try load(DocumentLaunchIntent.self,from:intentURL)
        let live = try TextEditProcessIdentity.read(candidate.pid)
        guard candidate.notBefore==intent.notBefore,live.birth>=intent.notBefore,live.birth<=candidate.callbackTime,
              candidate.birth.map({ $0==live.birth }) ?? (fromCallback && application != nil) else {
            throw TextEditIdentityRefusal("launchGeneration","callback did not identify the same newly born process")
        }
        if let app=application {
            guard app.processIdentifier==live.pid,!app.isTerminated,
                  app.bundleURL.map({ $0.standardizedFileURL.path==appURL.path }) ?? true,
                  app.bundleIdentifier.map({ $0=="com.apple.TextEdit" }) ?? true else {
                throw TextEditIdentityRefusal("launchServicesIdentity","published metadata conflicts with the kernel identity")
            }
        }
        let record=DocumentInstance(pid:live.pid,birth:live.birth,launch:application?.launchDate?.timeIntervalSince1970,
                                    hash:live.hash,consoleUID:live.uid,architecture:live.architecture)
        try save(record,to:receiptURL)
        return record
    }
    if request.mode == "open" {
        try guardInput()
        guard [receiptURL,intentURL,candidateURL].allSatisfy({ !manager.fileExists(atPath:$0.path) }), NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.TextEdit").isEmpty,
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
        let notBefore=try launchClock()
        try save(DocumentLaunchIntent(notBefore:notBefore),to:intentURL)
        NSWorkspace.shared.open(wanted,withApplicationAt:appURL,configuration:config) { app,error in
            do {
                guard let app,app.processIdentifier>1 else {throw TextEditIdentityRefusal("launchCallback","no receiver PID in the open reply")}
                let candidate=DocumentLaunchCandidate(pid:app.processIdentifier,birth:try? TextEditProcessIdentity.consoleBirth(app.processIdentifier),
                                                     notBefore:notBefore,callbackTime:try launchClock())
                try save(candidate,to:candidateURL)
                let record=try enroll(candidate,application:app,fromCallback:true)
                if error != nil {throw TextEditIdentityRefusal("openReply","Launch Services reported an open error after identifying the new process")}
                reply = .success(record)
            } catch { reply = .failure(error) }
        }
        let stop=Date().addingTimeInterval(8)
        while reply==nil, Date()<stop { RunLoop.current.run(until:Date().addingTimeInterval(0.03)) }
        guard let record=try reply?.get() else {throw TextEditIdentityRefusal("launchCallback","no callback before deadline")}
        var result=try JSONSerialization.jsonObject(with:JSONEncoder().encode(record)) as? Object ?? [:]
        result["launch"]=record.launch as Any? ?? NSNull()
        result["identityWitness"]="console kernel generation and Apple-signed matching Mach-O slice"
        return result
    }
    let enrolled: DocumentInstance
    if request.mode=="close",!manager.fileExists(atPath:receiptURL.path) {
        let candidate=try load(DocumentLaunchCandidate.self,from:candidateURL)
        enrolled=try enroll(candidate,application:NSRunningApplication(processIdentifier:candidate.pid))
    } else { enrolled=try load(DocumentInstance.self,from:receiptURL) }
    let live=try TextEditProcessIdentity.read(enrolled.pid)
    guard live.birth==enrolled.birth,live.hash==enrolled.hash,enrolled.architecture.map({ $0==live.architecture }) ?? true,
          enrolled.consoleUID.map({ $0==live.uid }) ?? true else {
        throw DocumentRefusal("kernel generation, console owner or signed system TextEdit executable changed or is unavailable")
    }
    let pairURL = folder.appendingPathComponent("bound-windows.json")
    let registered: DocumentWindowPair? = try manager.fileExists(atPath:pairURL.path) ? load(DocumentWindowPair.self,from:pairURL) : nil
    if let registered {
        guard registered.pid == enrolled.pid, registered.birth == enrolled.birth, registered.numbers.count == 2,
              Set(registered.numbers).count == 2, !registered.numbers.contains(0),
              request.numbers.map({ $0 == registered.numbers }) ?? true else { throw DocumentRefusal("durable window-pair enrollment changed") }
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
    func boundWindows(_ phase: String) throws -> [AXUIElement] {
        guard wanted.allSatisfy({ ownedDocumentNode($0.path,directory:false) }) else {throw DocumentRefusal("synthetic file ownership changed")}
        var note: Object = ["phase": phase, "start": ProcessInfo.processInfo.systemUptime, "binding": "notChecked"]
        defer { note["end"] = ProcessInfo.processInfo.systemUptime; reads.append(note) }
        var rootPID: pid_t = 0
        let rootError = AXUIElementGetPid(root, &rootPID)
        note["rootAXError"] = rootError.rawValue
        guard rootError == .success, rootPID == enrolled.pid else {
            note["status"] = "wrongOrUnreadableRoot"
            throw DocumentRefusal("TextEdit AXWindows root ownership unavailable")
        }
        let paths = wanted.compactMap { physicalDocumentPath($0.path) }
        guard paths.count == 2, Set(paths).count == 2 else { throw DocumentRefusal("synthetic files disappeared") }
        // Only resolve filesystem nodes already enrolled by the runner. Never stat a received foreign URL.
        func fileSlot(_ raw: String) -> Int? {
            guard let url = URL(string:raw), url.isFileURL, (url.host ?? "").isEmpty || url.host == "localhost",
                  url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil else { return nil }
            return paths.firstIndex { path in url.path == path || (path.hasPrefix("/private/tmp/") && url.path == String(path.dropFirst("/private".count))) }
        }
        func serverSurfaces() -> [UInt32]? {
            guard let list = CGWindowListCopyWindowInfo([.optionAll,.excludeDesktopElements],kCGNullWindowID), CFArrayGetCount(list) <= 4096 else { return nil }
            var numbers = [UInt32]()
            for row in list as NSArray {
                // Use the owner field solely as a filter. Read the number only for the enrolled process.
                guard let row = row as? NSDictionary, let pid = row.object(forKey:kCGWindowOwnerPID) as? pid_t else { return nil }
                guard pid == enrolled.pid else { continue }
                guard let n = row.object(forKey:kCGWindowNumber) as? UInt32 else { return nil }
                numbers.append(n)
                if numbers.count > TextEditWindowAliases.limit { break }
            }
            return numbers
        }
        func identify(_ w: AXUIElement) -> TextEditWindowAliases.Identity {
            var pid: pid_t = 0
            let code = AXUIElementGetPid(w,&pid)
            guard code == .success, pid == enrolled.pid else {
                return .init(owner:code == .success ? "other" : "unreadable",number:0,role:"unreadable",subrole:"unreadable")
            }
            let role = value(w,kAXRoleAttribute) as? String
            let sub = value(w,kAXSubroleAttribute) as? String
            let roles = [kAXWindowRole:"window", kAXSheetRole:"sheet"]
            let subroles = [kAXStandardWindowSubrole:"standard", kAXDialogSubrole:"dialog", kAXFloatingWindowSubrole:"floating",
                            kAXSystemDialogSubrole:"systemDialog", kAXUnknownSubrole:"unknown"]
            return .init(owner:"enrolled",number:NPReadAXWindowNumber(w),role:role.map { roles[$0] ?? "other" } ?? "unreadable",
                         subrole:sub.map { subroles[$0] ?? "other" } ?? "unreadable")
        }
        let observed = TextEditWindowList.read(root)
        note.merge(observed.evidence) { _, new in new }
        if observed.status == "additionalWindowsReported", let n = observed.evidence["reportedCount"] as? Int,
           (3...TextEditWindowAliases.limit).contains(n) {
            let (state,pair,checks) = TextEditWindowAliases.prove(expected:registered?.numbers, interruption:{
                guard TextEditProcessIdentity.kernelBirth(enrolled.pid) == enrolled.birth else { return "generationChanged" }
                return textInputCounters() == request.hid && NSEvent.pressedMouseButtons == 0 ? nil : "physicalInputChanged"
            },read:{ TextEditWindowAliases.read(enrolled.pid) },same:{ CFEqual($0,$1) }, identify:identify, surfaces:serverSurfaces,
               between:{ Thread.sleep(forTimeInterval:0.04) }, matchesFile:{ window,slot in
                guard let numbers = registered?.numbers, numbers.count == 2, owner(window) == enrolled.pid,
                      NPReadAXWindowNumber(window) == numbers[slot],
                      let raw = value(window,kAXDocumentAttribute) as? String else { return nil }
                return fileSlot(raw) == slot
            })
            note["expandedState"] = state
            note["expandedReads"] = checks
            guard let pair else { throw DocumentRefusal("TextEdit AXWindows \(phase) bounded excess-count read: \(state)") }
            note["binding"] = "bothEnrolledURLs"
            note["status"] = "verifiedExpandedPair"
            return pair
        }
        guard let windows = observed.windows else {
            throw DocumentRefusal("TextEdit AXWindows \(phase) read: \(observed.status)")
        }
        var result=[String:AXUIElement]()
        for window in windows {
            guard owner(window)==enrolled.pid else {
                note["binding"] = "wrongOrUnreadableWindowOwner"
                throw DocumentRefusal("AX window is not bound to the enrolled TextEdit PID")
            }
            var role: CFTypeRef?
            let roleError = AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role)
            guard roleError == .success, let role, CFGetTypeID(role) == CFStringGetTypeID(), role as? String == kAXWindowRole else {
                note["binding"] = roleError == .success ? "wrongWindowRole" : "roleAXError"
                note["roleAXError"] = roleError.rawValue
                throw DocumentRefusal("AX window role unavailable for the enrolled TextEdit process")
            }
            if let expected = registered?.numbers ?? request.numbers, !expected.contains(NPReadAXWindowNumber(window)) {
                note["binding"] = "unregisteredWindowNumber"
                throw DocumentRefusal("AX window number differs from the previously enrolled pair")
            }
            var document: CFTypeRef?
            let code = AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &document)
            guard code == .success, let document, CFGetTypeID(document) == CFStringGetTypeID(), let raw = document as? String else {
                note["binding"] = code == .success ? "documentValueNotString" : "documentAXError"
                note["documentAXError"] = code.rawValue
                throw DocumentRefusal("could not verify the local AX document URL")
            }
            guard let slot = fileSlot(raw), result[paths[slot]] == nil else {
                note["binding"] = "foreignOrDuplicateURL"
                throw DocumentRefusal("a window is not bound to the disposable document URLs")
            }
            result[paths[slot]]=window
        }
        let ordered = try paths.map { guard let w=result[$0] else {throw DocumentRefusal("test document missing")}; return w }
        if let expected = registered?.numbers ?? request.numbers, ordered.map({ NPReadAXWindowNumber($0) }) != expected {
            note["binding"] = "unregisteredWindowNumber"
            throw DocumentRefusal("enrolled window numbers no longer identify their original files")
        }
        note["binding"] = "bothEnrolledURLs"
        return ordered
    }
    if request.mode != "close" {try guardInput()}
    let windows=try boundWindows("initial")
    if request.mode=="close" {
        // A new user document in our process revokes permission to terminate it.
        guard let app=NSRunningApplication(processIdentifier:enrolled.pid),app.processIdentifier==live.pid,!app.isTerminated,
              app.bundleURL.map({ $0.standardizedFileURL.path==appURL.path }) ?? true,
              app.bundleIdentifier.map({ $0=="com.apple.TextEdit" }) ?? true,
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
        let current=try boundWindows("recheck")
        guard zip(current,windows).allSatisfy({ CFEqual($0,$1) }),current.map({ NPReadAXWindowNumber($0) })==numbers,
              numbers.allSatisfy({ NPReadWindowSpaces($0) as? [UInt64] == [request.space] }) else {
            throw DocumentRefusal("enrolled document windows or Space changed")
        }
    }
    func guardBoundary() throws {
        guard TextEditProcessIdentity.kernelBirth(enrolled.pid)==enrolled.birth,
              birthMicroseconds(request.hostPID)==request.hostBirth,
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
        if registered == nil {
            let binding = DocumentWindowPair(pid:enrolled.pid,birth:enrolled.birth,numbers:numbers)
            do { try save(binding,to:pairURL) }
            catch {
                guard (try? load(DocumentWindowPair.self,from:pairURL)) == binding else {
                    throw DocumentRefusal("could not retain the original two-window enrollment")
                }
            }
        }
        return ["numbers":numbers,"focused":numbers[final.focused],"main":final.main.map { numbers[$0] } ?? 0,"front":true,
                "focusWitness":"systemAX","pid":enrolled.pid,"hashes":hashes,
                "markerCounts":strings.map { marker.isEmpty ? 0 : $0.components(separatedBy:marker).count-1 }]
    }
    guard let i=request.index, (0..<2).contains(i), let host else {
        throw DocumentRefusal("test document lost foreground ownership")
    }
    guard registered?.numbers == numbers, request.numbers == numbers, request.target == numbers[i] else { throw DocumentRefusal("enrolled window pair or target window number changed") }
    if request.mode == "ready" || request.mode == "press" {
        let id="current-desktop-window:\(enrolled.pid):\(numbers[i])"
        let (exact, info) = documentControl(host,id:id,display:request.display)
        controlRead = info
        try guardInput()
        try verifyWindows()
        if request.mode == "ready" {
            guard try focus().focused == initial.focused else { throw DocumentRefusal("focused document changed while reading sidebar control") }
            try guardBoundary()
            return ["control":id, "hostPID":host.processIdentifier, "hostBirth":request.hostBirth, "hostHash":request.hostHash,
                    "documentBirth":enrolled.birth, "numbers":numbers, "display":request.display, "space":request.space]
        }
        guard let exact else { throw DocumentRefusal("installed sidebar control unavailable before press: \(info["state"] ?? "unknown")") }
        guard let panel = request.panel, panel > 0, info["panel"] as? UInt32 == panel else { throw DocumentRefusal("installed sidebar panel changed before press") }
        guard owner(exact)==host.processIdentifier,value(exact,kAXIdentifierAttribute) as? String==id,
              value(exact,kAXEnabledAttribute) as? Bool==true, try focus().focused==initial.focused else {
            throw DocumentRefusal("sidebar control or focused document changed before press")
        }
        try guardBoundary()
        let error=AXUIElementPerformAction(exact,kAXPressAction as CFString)
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

var documentWindowReads = [Object]()
var documentControlRead: Object?
do {
    let request=try JSONDecoder().decode(DocumentRequest.self,from:FileHandle.standardInput.readDataToEndOfFile())
    var result=try textDocuments(request, reads: &documentWindowReads, controlRead: &documentControlRead)
    if let documentControlRead { result["controlRead"] = documentControlRead }
    if !documentWindowReads.isEmpty { result["windowReads"] = documentWindowReads }
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:result)+Data([10]))
} catch {
    // Only our explicit guards prove that this invocation stopped before AXPress.
    let refusal = error as? DocumentRefusal
    let identity = error as? TextEditIdentityRefusal
    var reply: Object = ["issued": refusal == nil && identity == nil ? NSNull() as Any : false,
                         "stage":identity?.stage as Any? ?? NSNull(),
                         "reason": identity?.reason ?? refusal?.reason ?? "system document helper did not produce a confirmed reply"]
    if let documentControlRead { reply["controlRead"] = documentControlRead }
    if !documentWindowReads.isEmpty { reply["windowReads"] = documentWindowReads }
    FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject:reply)+Data([10]));exit(2)
}
