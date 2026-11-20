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
