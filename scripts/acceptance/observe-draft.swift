import AppKit
import Carbon

// The authorized checkpoint has its own code identity. Address one running process and tab by ID.
// No browser launch, tab selection, window activation, file input or consent request.
@main struct DraftObserver {
    static func code(_ value: String) -> UInt32 { value.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }

    static func object(_ kind: String, _ form: String, _ key: NSAppleEventDescriptor,
                       _ container: NSAppleEventDescriptor = .null()) throws -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        for (name, value) in [("want", NSAppleEventDescriptor(typeCode: code(kind))),
                              ("form", .init(enumCode: code(form))), ("seld", key), ("from", container)] {
            record.setDescriptor(value, forKeyword: code(name))
        }
        guard let item = record.coerce(toDescriptorType: code("obj ")) else { throw CocoaError(.fileReadCorruptFile) }
        return item
    }

    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 3, let pid = Int32(args[0]), let w = Int64(args[1]), let t = Int64(args[2]), w > 0, t > 0,
              let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier == "com.google.Chrome", !app.isTerminated
        else { throw CocoaError(.fileReadNoPermission) }
        let address = NSAppleEventDescriptor(processIdentifier: pid)
        guard AEDeterminePermissionToAutomateTarget(address.aeDesc,typeWildCard,typeWildCard,false) == noErr
        else { throw CocoaError(.fileReadNoPermission) }
        func send(_ suite: String,_ verb: String,_ direct: NSAppleEventDescriptor, script: String? = nil) throws -> NSAppleEventDescriptor {
            let e = NSAppleEventDescriptor(eventClass: code(suite), eventID: code(verb), targetDescriptor: address, returnID: -1, transactionID: 0)
            e.setParam(direct,forKeyword: code("----"))
            if let script { e.setParam(.init(string: script),forKeyword: code("JvSc")) }
            let reply = try e.sendEvent(options: [.waitForReply,.neverInteract],timeout: 3)
            guard (reply.paramDescriptor(forKeyword: code("errn"))?.int32Value ?? 0) == 0,
                  let value = reply.paramDescriptor(forKeyword: code("----")) else { throw CocoaError(.fileReadNoPermission) }
            return value
        }
        let front = try object("cwin","indx",.init(int32: 1))
        let window = try object("cwin","ID  ",.init(string: args[1]))
        let tab = try object("CrTb","ID  ",.init(string: args[2]),window)
        func property(_ key: String,_ from: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
            try send("core","getd",object("prop","prop",.init(typeCode: code(key)),from))
        }
        func selected() throws -> Bool {
            guard !app.isTerminated, try property("ID  ",front).stringValue == args[1] else { return false }
            return try property("ID  ",property("acTa",window)).stringValue == args[2]
        }
        let bytes = FileHandle.standardInput.readData(ofLength: 65537)
        guard bytes.count <= 65536, let source = String(data: bytes,encoding: .utf8), try selected(),
              let result = try send("CrSu","ExJa",tab,script: source).stringValue, result.utf8.count <= 262144,
              try selected() else { throw CocoaError(.fileReadNoPermission) }
        print(result)
    }
}
