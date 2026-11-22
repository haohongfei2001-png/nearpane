import AppKit
import ApplicationServices
import CNearpaneWindowEngine
import NearpaneCore
import NearpaneOrdinaryWindowRuntime
import Security

/// Two-party P1 verification. This helper never activates the fixture, writes AX attributes, or posts input.
@main struct FixtureReadback {
    struct Unavailable: Error {}
    static func attribute(_ element: AXUIElement, _ key: String) throws -> CFTypeRef {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,key as CFString,&value) == .success, let value else { throw Unavailable() }
        return value
    }
    static func dock() throws -> [String:Any] {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.dock")
        var requirement: SecRequirement?, code: SecCode?
        guard apps.count == 1, let app = apps.first,
              app.bundleURL?.path == "/System/Library/CoreServices/Dock.app",
              SecRequirementCreateWithString("anchor apple and identifier \"com.apple.dock\"" as CFString,[],&requirement) == errSecSuccess,
              let requirement, SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid as String:app.processIdentifier] as CFDictionary,[],&code) == errSecSuccess,
              let code, SecCodeCheckValidity(code,[],requirement) == errSecSuccess else { throw Unavailable() }
        let owner = try OrdinaryProcessImage.read(app.processIdentifier)
        let root = AXUIElementCreateApplication(owner.pid)
        guard AXUIElementSetMessagingTimeout(root,0.2) == .success,
              let top = try attribute(root,kAXChildrenAttribute) as? [AXUIElement] else { throw Unavailable() }
        let lists = top.filter { (try? attribute($0,kAXRoleAttribute)) as? String == kAXListRole }
        guard lists.count == 1, let list = lists.first, let children = try attribute(list,kAXChildrenAttribute) as? [AXUIElement],
              !children.isEmpty, children.count <= 256 else { throw Unavailable() }
        var subroles = [String]()
        for item in children {
            var pid: pid_t = 0
            guard AXUIElementGetPid(item,&pid) == .success, pid == owner.pid,
                  let role = try attribute(item,kAXSubroleAttribute) as? String else { throw Unavailable() }
            subroles.append(role)
        }
        guard try OrdinaryProcessImage.read(owner.pid) == owner else { throw Unavailable() }
        return ["pid":owner.pid,"birth":owner.launch,"orderedSubroles":subroles]
    }
    @MainActor static func main() async {
        var row: [String:Any] = ["status":"UNKNOWN","windowWrites":0,"spaceWrites":0]
        do {
            let a = CommandLine.arguments
            guard a.count == 7, ["--registered","--trace-membership"].contains(a[1]), let challenge = UUID(uuidString:a[2]),
                  let pid = Int32(a[3]), let birth = UInt64(a[4]), let n = UInt32(a[5]), pid > 1, birth > 0, n > 0,
                  AXIsProcessTrusted() else { throw Unavailable() }
            let path = URL(fileURLWithPath:"/private/tmp/nearpane-membership." + challenge.uuidString.lowercased())
                .appendingPathComponent("Membership Window.app/Contents/MacOS/MembershipWindow")
            let f = StageEngineHostScope.Fixture(pid:pid,birth:birth,number:n,executable:path,cdhash:a[6])
            let scope = await StageEngineHostScope.sample(fixture:f)
            row["scope"] = scope["scope"]
            row["membership"] = scope["fixtureMembership"]
            row["samples"] = (scope["samples"] as? [[String:Any]])?.map { ["managedRows":$0["managedRows"],"fixture":$0["fixture"]] }
            guard (scope["fixtureMembership"] as? [String:Any])?["status"] as? String == "PASS" else { throw Unavailable() }
            let root = AXUIElementCreateApplication(pid)
            guard AXUIElementSetMessagingTimeout(root,0.25) == .success,
                  let windows = try attribute(root,kAXWindowsAttribute) as? [AXUIElement] else { throw Unavailable() }
            let exact = windows.filter { NearpaneOrdinaryWindowRuntime.number($0) == n }
            guard exact.count == 1, let w = exact.first else { throw Unavailable() }
            if a[1] == "--trace-membership" {
                guard let ordinary = scope["scope"] as? [String:Any], ordinary["status"] as? String == "PASS",
                      let home = ordinary["nativeID"] as? UInt64,
                      let display = (scope["samples"] as? [[String:Any]])?.first?["managedDisplayToken"] as? String
                else { throw Unavailable() }
                try await trace(f, retained: w, home: home, display: display, challenge: challenge)
                return
            }
            let p = try attribute(w,kAXPositionAttribute), s = try attribute(w,kAXSizeAttribute)
            var xy = CGPoint.zero, size = CGSize.zero
            guard CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID(),
                  AXValueGetValue(p as! AXValue,.cgPoint,&xy), AXValueGetValue(s as! AXValue,.cgSize,&size),
                  let cg = CGWindowListCopyWindowInfo(.optionIncludingWindow,n) as? [[String:Any]], cg.count == 1,
                  cg[0][kCGWindowOwnerPID as String] as? Int32 == pid, cg[0][kCGWindowNumber as String] as? UInt32 == n,
                  let box = cg[0][kCGWindowBounds as String] as? NSDictionary,
                  let visible = CGRect(dictionaryRepresentation:box) else { throw Unavailable() }
            let ax = CGRect(origin:xy,size:size)
            row["axFrame"] = StageOverviewHitTest.box(ax)
            row["cgFrame"] = StageOverviewHitTest.box(visible)
            row["focus"] = StageCanaryOverview.admission()
            row["dock"] = try dock()
            guard !ax.isEmpty, ax == visible, try OrdinaryProcessImage.read(pid).launch == birth,
                  (row["focus"] as? [String:Any])?["cgWindowID"] != nil else { throw Unavailable() }
            row["status"] = "PASS"
        } catch { row["reason"] = "independentFixtureFocusDockOrGeometryUnavailable" }
        if let data = try? JSONSerialization.data(withJSONObject:row,options:.sortedKeys) { FileHandle.standardOutput.write(data) }
    }

    /// Observe the registered target independently while the Host performs its bounded operation.
    /// Closing stdin stops the observer. It never holds up the Host's return or cleanup.
    @MainActor private static func trace(_ f: StageEngineHostScope.Fixture, retained: AXUIElement, home: UInt64,
                                         display: String, challenge: UUID) async throws {
        func emit(_ row: [String:Any]) throws {
            try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject:row) + Data([10]))
        }
        let image = try OrdinaryProcessImage.read(f.pid)
        guard image.launch == f.birth else { throw Unavailable() }
        var error: Int32 = 0, connection: Int32 = 0
        guard np_host_scope_copy_managed(&connection, &error) != nil, error == 0 else { throw Unavailable() }
        let baselineInput = StageCanaryOverview.hid()
        let deadline = ContinuousClock.now + .seconds(75)
        var stop = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        var count = 0
        try emit(["event":"bound","pid":f.pid,"birth":f.birth,"window":f.number,"cdhash":f.cdhash,
                  "challenge":challenge.uuidString.lowercased(),"home":home])
        while ContinuousClock.now < deadline && count < 4500 {
            guard poll(&stop,1,0) == 0 else { break }
            var row: [String:Any] = ["event":"sample","start":ProcessInfo.processInfo.systemUptime]
            var owner: pid_t = 0
            guard AXUIElementGetPid(retained,&owner) == .success, owner == f.pid,
                  NearpaneOrdinaryWindowRuntime.number(retained) == f.number,
                  try OrdinaryProcessImage.read(f.pid) == image,
                  np_host_scope_direct(connection,display as CFString,&error) == home, error == 0,
                  StageCanaryOverview.hid() == baselineInput, NSEvent.pressedMouseButtons == 0
            else { throw Unavailable() }
            let first = np_host_scope_reverse(connection,f.number,&error) as? [NSNumber]
            let firstError = error
            if firstError == 0, let first, first.count == 1, let observed = first.first?.uint64Value, observed > 0 {
                let homeHits = np_host_scope_forward_hits(connection,home,f.number,&error)
                let homeError = error
                let memberHits = observed == home ? homeHits : np_host_scope_forward_hits(connection,observed,f.number,&error)
                let memberError = error
                let second = np_host_scope_reverse(connection,f.number,&error) as? [NSNumber]
                if error == 0, second == first, homeError == 0, memberError == 0 {
                    row["space"] = observed
                    row["homeHits"] = homeHits
                    row["spaceHits"] = memberHits
                }
            }
            row["end"] = ProcessInfo.processInfo.systemUptime
            try emit(row)
            count += 1
            try await Task.sleep(for:.milliseconds(18))
        }
        guard stop.revents != 0, try OrdinaryProcessImage.read(f.pid) == image,
              StageCanaryOverview.hid() == baselineInput, NSEvent.pressedMouseButtons == 0 else { throw Unavailable() }
        try emit(["event":"closed","samples":count])
    }
}
