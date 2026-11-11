import AppKit
import Carbon

/// A PID-addressed, nonprompting route read shared by the fixture Host and its observation helper.
struct AcceptanceBrowserRoute {
    let app: NSRunningApplication
    let address: NSAppleEventDescriptor
    let windowID, tabID: String

    /// Resolve the current front window and its selected tab without reading other tabs.
    static func front(pid: Int32) throws -> Self {
        // The seed is used only to authorize the PID and form a front-window index specifier.
        let pidRoute = try Self(pid: pid, window: "1", tab: "1")
        let front = try pidRoute.object("cwin","indx",.init(int32: 1))
        guard let window = try pidRoute.property("ID  ",front).stringValue,
              let tab = try pidRoute.property("ID  ",pidRoute.property("acTa",front)).stringValue else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let fixed = try Self(pid: pid, window:window, tab:tab)
        guard try fixed.selected() else { throw CocoaError(.fileReadNoPermission) }
        return fixed
    }

    func selectedURL() throws -> URL {
        let window = try object("cwin","ID  ",.init(string:windowID))
        let tab = try object("CrTb","ID  ",.init(string:tabID),window)
        guard try selected(), let raw = try property("URL ",tab).stringValue, let url = URL(string: raw),
              try selected() else { throw CocoaError(.fileReadNoPermission) }
        return url
    }

    init(pid: Int32, window: String, tab: String) throws {
        guard let w = Int64(window), let t = Int64(tab), w > 0, t > 0,
              let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier == "com.google.Chrome", !app.isTerminated
        else { throw CocoaError(.fileReadNoPermission) }
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
        let reply = try e.sendEvent(options: [.waitForReply,.neverInteract],timeout: 3)
        guard (reply.paramDescriptor(forKeyword: code("errn"))?.int32Value ?? 0) == 0,
              let value = reply.paramDescriptor(forKeyword: code("----")) else { throw CocoaError(.fileReadNoPermission) }
        return value
    }
    private func property(_ key: String,_ from: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        try send("core","getd",object("prop","prop",.init(typeCode: code(key)),from))
    }

    func selected() throws -> Bool {
        guard !app.isTerminated, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return false }
        let front = try object("cwin","indx",.init(int32: 1))
        let window = try object("cwin","ID  ",.init(string: windowID))
        guard try property("ID  ",front).stringValue == windowID else { return false }
        return try property("ID  ",property("acTa",window)).stringValue == tabID
    }

    func observe(_ source: String) throws -> String {
        let window = try object("cwin","ID  ",.init(string: windowID))
        let tab = try object("CrTb","ID  ",.init(string: tabID),window)
        guard try selected(), let result = try send("CrSu","ExJa",tab,script: source).stringValue,
              result.utf8.count <= 262144, try selected() else { throw CocoaError(.fileReadNoPermission) }
        return result
    }
}
