import ApplicationServices
import Darwin
import Foundation

// In-memory AX values only. No window, event or access to a running desktop application.
private final class Fixture {
    let pid: pid_t = 47
    // 0 system, 1 enrolled app, 2/3 A/B, 4/5 editors, 9 another application.
    var attributes = [0: [kAXFocusedApplicationAttribute: 1, kAXFocusedUIElementAttribute: 4],
                      1: [kAXFocusedWindowAttribute: 2, kAXMainWindowAttribute: 2, kAXFocusedUIElementAttribute: 4]]
    var laterApp: Int?, laterKey: Int?, laterEditor: Int?
    var appReads = 0, keyReads = 0, editorReads = 0, visitedForeignApp = false

    func indices(editor: Int? = nil) -> (focused: Int, main: Int?)? {
        appReads = 0; keyReads = 0; editorReads = 0; visitedForeignApp = false
        let reader = TextEditFocusReader<Int>(read: { node, key in
            if node == 9 { self.visitedForeignApp = true }
            if node == 0 && key == kAXFocusedApplicationAttribute {
                self.appReads += 1
                if self.appReads > 1, let later = self.laterApp { return later }
            }
            if node == 1 && key == kAXFocusedWindowAttribute {
                self.keyReads += 1
                if self.keyReads > 2, let later = self.laterKey { return later }
            }
            if node == 0 && key == kAXFocusedUIElementAttribute {
                self.editorReads += 1
                if self.editorReads > 1, let later = self.laterEditor { return later }
            }
            return self.attributes[node]?[key]
        }, owner: { (1...5).contains($0) ? self.pid : 88 }, same: { $0 == $1 })
        return reader.indices(system: 0, root: 1, pid: pid, windows: [2, 3], editor: editor)
    }
}

@main struct W01IdentityTests {
    static func main() throws {
        let slices = CommandLine.arguments.dropFirst()
        precondition(!slices.isEmpty)
        for slice in slices {
            let parts = slice.split(separator: ":")
            let arch = TextEditArchitecture(cpu: Int32(parts[0])!, subtype: Int32(parts[1])!)
            let hash = try TextEditProcessIdentity.systemCodeHash(for: arch).map { String(format: "%02x", $0) }.joined()
            precondition(hash == parts[2], "verified disk slice must agree with codesign for that architecture")
        }
        precondition((try? TextEditProcessIdentity.read(getpid())) == nil, "test process must never satisfy TextEdit enrollment")
        // Construct opaque AX identities for nonexistent PIDs without sending an AX request.
        let pair = [AXUIElementCreateApplication(2_100_000_000), AXUIElementCreateApplication(2_100_000_001)] as CFArray
        func read(_ count: (AXError, Int), _ copy: (AXError, CFTypeRef?)) -> TextEditWindowList {
            TextEditWindowList.inspect(count: { count }, copy: { copy })
        }
        precondition(read((.success, 2), (.success, pair)).windows?.count == 2)
        precondition(read((.attributeUnsupported, 0), (.success, pair)).windows?.count == 2)
        let emptyRead = read((.success, 0), (.success, [] as CFArray))
        precondition(emptyRead.status == "emptyArray" && emptyRead.windows == nil)
        precondition(read((.success, 1), (.success, [AXUIElementCreateApplication(2_100_000_000)] as CFArray)).status == "oneWindow")
        precondition(read((.success, 2), (.cannotComplete, nil)).status == "arrayAXError")
        precondition(read((.success, 2), (.success, nil)).status == "missingArrayValue")
        precondition(read((.success, 2), (.success, "not an array" as CFString)).status == "nonArrayValue")
        precondition(read((.success, 2), (.success, ["wrong", "type"] as CFArray)).status == "invalidArrayMembers")
        precondition(read((.success, 1), (.success, pair)).status == "countChanged")
        precondition(read((.cannotComplete, 0), (.success, ["a", "b", "c"] as CFArray)).status == "additionalWindowsReturned")
        for (count, label) in [((AXError.success, 3), "additionalWindowsReported"), ((.apiDisabled, 0), "windowCountRefused"), ((.invalidUIElement, 0), "windowCountRefused")] {
            let omitted = TextEditWindowList.inspect(count: { count }, copy: { fatalError("must not enumerate unqualified windows") })
            precondition(omitted.status == label && omitted.evidence["copyAXError"] == nil)
        }
        for (count, rosters, expected) in [(0, 0, "rosterUnavailable"), (0, 1, "missing"), (2, 1, "duplicate")] {
            precondition(TextEditSidebarButtonRead.matchState(count:count,rosterCount:rosters) == expected)
        }
        precondition(TextEditSidebarButtonRead.matchState(count:1,rosterCount:1) == nil)
        precondition(TextEditSidebarButtonRead.enabled(status:.success,value:kCFBooleanTrue) == true)
        precondition(TextEditSidebarButtonRead.enabled(status:.success,value:kCFBooleanFalse) == false)
        precondition(TextEditSidebarButtonRead.enabled(status:.success,value:NSNumber(value:7)) == nil)
        precondition(TextEditSidebarButtonRead.enabled(status:.success,value:nil) == nil)
        precondition(TextEditSidebarButtonRead.enabled(status:.cannotComplete,value:kCFBooleanTrue) == nil)
        let fixture = Fixture()
        precondition(fixture.indices()?.focused == 0 && fixture.indices(editor: 4)?.main == 0)
        precondition(fixture.indices(editor: 5) == nil)
        fixture.attributes[0]?[kAXFocusedApplicationAttribute] = nil
        precondition(fixture.indices() == nil)
        fixture.attributes[0]?[kAXFocusedApplicationAttribute] = 9
        precondition(fixture.indices() == nil && !fixture.visitedForeignApp)
        fixture.attributes[0]?[kAXFocusedApplicationAttribute] = 1
        fixture.laterApp = 9
        precondition(fixture.indices(editor: 4) == nil && !fixture.visitedForeignApp)
        fixture.laterApp = nil
        fixture.laterKey = 3
        precondition(fixture.indices(editor: 4) == nil)
        fixture.laterKey = nil
        fixture.laterEditor = 5
        precondition(fixture.indices(editor: 4) == nil)
        fixture.laterEditor = nil
        fixture.attributes[1]?[kAXMainWindowAttribute] = 3
        precondition(fixture.indices()?.main == 1 && fixture.indices(editor: 4) == nil)
        fixture.attributes[1]?[kAXMainWindowAttribute] = 2
        fixture.attributes[0]?[kAXFocusedUIElementAttribute] = 5
        precondition(fixture.indices(editor: 4) == nil)
        fixture.attributes[0]?[kAXFocusedUIElementAttribute] = 9
        precondition(fixture.indices(editor: 4) == nil && !fixture.visitedForeignApp)
        fixture.attributes[1]?[kAXFocusedWindowAttribute] = 9
        precondition(fixture.indices() == nil && !fixture.visitedForeignApp)
    }
}
