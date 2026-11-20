import AppKit
import Carbon
import NearpaneCore

/// A PID-addressed, nonprompting route read shared by the fixture Host and its observation helper.
struct AcceptanceBrowserRoute {
    enum ScriptError: Error { case javaScriptFromAppleEventsDenied }
    let browser: DraftBrowser
    private let process: OrdinaryProcessImage
    let app: NSRunningApplication
    let address: NSAppleEventDescriptor
    let windowID, tabID: String

    /// Resolve the current front window and its selected tab without reading other tabs.
    static func front(pid: Int32, browser: DraftBrowser = .chrome) throws -> Self {
        guard browser.hasStableTabID, browser.signed(pid:pid) else { throw CocoaError(.fileReadNoPermission) }
        // The seed is used only to authorize the PID and form a front-window index specifier.
        let pidRoute = try Self(pid: pid, window: "1", tab: "1", browser:browser)
        let front = try pidRoute.object("cwin","indx",.init(int32: 1))
        guard let window = try pidRoute.property("ID  ",front).stringValue,
              let tab = try pidRoute.property("ID  ",pidRoute.property("acTa",front)).stringValue else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let fixed = try Self(pid: pid, window:window, tab:tab, browser:browser)
        guard try fixed.selected() else { throw CocoaError(.fileReadNoPermission) }
        return fixed
    }

    var witness: DraftAddress {
        .init(browser:browser,pid:process.pid,processBirth:process.launch,windowID:windowID,tabID:browser.hasStableTabID ? tabID:nil)
    }
    static func safariWindow(pid:Int32) throws -> DraftAddress {
        guard DraftBrowser.safari.signed(pid:pid) else {throw CocoaError(.fileReadNoPermission)}
        let seed=try Self(pid:pid,window:"1",tab:"",browser:.safari)
        let front=try seed.object("cwin","indx",.init(int32:1))
        guard let window=try seed.property("ID  ",front).stringValue else {throw CocoaError(.fileReadNoPermission)}
        let pinned=try Self(pid:pid,window:window,tab:"",browser:.safari)
        guard pinned.process==seed.process,try pinned.selected() else {throw CocoaError(.fileReadNoPermission)}
        return pinned.witness
    }
    func selectedURL() throws -> URL {
        let window = try object("cwin","ID  ",.init(string:windowID))
        let tab = try object("CrTb","ID  ",.init(string:tabID),window)
        guard try selected(), let raw = try property("URL ",tab).stringValue, let url = URL(string: raw),
              try selected() else { throw CocoaError(.fileReadNoPermission) }
        return url
    }

    init(pid: Int32, window: String, tab: String,browser: DraftBrowser = .chrome) throws {
        guard let w = Int64(window), w > 0, browser.hasStableTabID ? (Int64(tab) ?? 0)>0 : tab.isEmpty, let process=try? OrdinaryProcessImage.read(pid),
              let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier == browser.rawValue, !app.isTerminated
        else { throw CocoaError(.fileReadNoPermission) }
        self.browser = browser
        self.process = process
        self.app = app
        address = NSAppleEventDescriptor(processIdentifier: pid)
        windowID = window; tabID = tab
        guard AEDeterminePermissionToAutomateTarget(address.aeDesc,typeWildCard,typeWildCard,false) == noErr
        else { throw CocoaError(.fileReadNoPermission) }
    }
    private func code(_ value: String) -> UInt32 { value.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }

    private func object(_ kind: String, _ form: String, _ key: NSAppleEventDescriptor,
                       _ container: NSAppleEventDescriptor = .null()) throws -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        for (name, value) in [("want", NSAppleEventDescriptor(typeCode: code(kind))),
                              ("form", .init(enumCode: code(form))), ("seld", key), ("from", container)] {
            record.setDescriptor(value, forKeyword: code(name))
        }
        guard let item = record.coerce(toDescriptorType: code("obj ")) else { throw CocoaError(.fileReadCorruptFile) }
        return item
    }

    private func send(_ suite: String,_ verb: String,_ direct: NSAppleEventDescriptor, script: String? = nil) throws -> NSAppleEventDescriptor {
        let e = NSAppleEventDescriptor(eventClass: code(suite), eventID: code(verb), targetDescriptor: address, returnID: -1, transactionID: 0)
        e.setParam(direct,forKeyword: code("----"))
        if let script { e.setParam(.init(string: script),forKeyword: code("JvSc")) }
        return try Self.checkedReply(executingJavaScript: script != nil) {
            try e.sendEvent(options: [.waitForReply,.neverInteract],timeout: 3)
        }
    }

    static func checkedReply(executingJavaScript: Bool, send: () throws -> NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let reply: NSAppleEventDescriptor
        do { reply = try send() }
        catch {
            let native = error as NSError
            if executingJavaScript, native.domain == NSOSStatusErrorDomain, native.code == 12 {
                throw ScriptError.javaScriptFromAppleEventsDenied
            }
            throw CocoaError(.fileReadNoPermission)
        }
        let status = reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value ?? 0
        if executingJavaScript, status == 12 { throw ScriptError.javaScriptFromAppleEventsDenied }
        guard status == 0, let value = reply.paramDescriptor(forKeyword: keyDirectObject) else {
            throw CocoaError(.fileReadNoPermission)
        }
        return value
    }
    private func property(_ key: String,_ from: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        try send("core","getd",object("prop","prop",.init(typeCode: code(key)),from))
    }

    func selected() throws -> Bool {
        guard !app.isTerminated, (try? OrdinaryProcessImage.read(app.processIdentifier)) == process, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return false }
        let front = try object("cwin","indx",.init(int32: 1))
        let window = try object("cwin","ID  ",.init(string: windowID))
        guard try property("ID  ",front).stringValue == windowID else { return false }
        if browser == .safari {return true}
        return try property("ID  ",property("acTa",window)).stringValue == tabID
    }

    func inspect(_ route:DraftCapability, selected url:URL, guardSource:String) throws -> DraftBoundSurface {
        guard browser.hasStableTabID,self.browser == route.browser, DraftCapability.route(browserID:browser.rawValue,url:url)==route,
              try selectedURL()==url else { throw CocoaError(.fileReadNoPermission) }
        let text=try executeInSelectedTab(route.readOnlyScript(guardSource:guardSource))
        let surface=try JSONDecoder().decode(DraftSurface.self,from:Data(text.utf8))
        guard surface.service==route.service.rawValue,try selectedURL()==url else {throw CocoaError(.fileReadNoPermission)}
        return DraftBoundSurface(address:witness,surface:surface)
    }
    func observe(_ source: String) throws -> String {
        guard browser == .chrome else { throw CocoaError(.fileReadNoPermission) }
        return try executeInSelectedTab(source)
    }
    private func executeInSelectedTab(_ source: String) throws -> String {
        let window = try object("cwin","ID  ",.init(string: windowID))
        let tab = try object("CrTb","ID  ",.init(string: tabID),window)
        guard try selected(), let result = try send("CrSu","ExJa",tab,script: source).stringValue,
              result.utf8.count <= 262144, try selected() else { throw CocoaError(.fileReadNoPermission) }
        return result
    }
}
