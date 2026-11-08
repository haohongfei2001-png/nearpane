import Foundation

// Used only after explicit browser authorization. Compiled with the same route reader as the fixture Host.
@main struct DraftObserver {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 3, let pid = Int32(args[0]) else { throw CocoaError(.fileReadNoPermission) }
        let route = try AcceptanceBrowserRoute(pid: pid,window: args[1],tab: args[2])
        let bytes = FileHandle.standardInput.readData(ofLength: 65537)
        guard bytes.count <= 65536, let source = String(data: bytes,encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        print(try route.observe(source))
    }
}
