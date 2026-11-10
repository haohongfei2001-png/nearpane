import AppKit
import ApplicationServices
import Darwin
import NearpaneCore
import WindowLab

struct Observation: Codable {
    let member: Member, cg: SurfaceRect, ax: SurfaceRect?, onScreen: Bool
}

@MainActor final class FixtureAdapter {
    let directory: URL, run: Run, ticket: OwnerState
    private(set) var setters = 0
    let acceptsAX: Bool
    init(_ directory: URL, acceptsAX: Bool = true) throws {
        self.acceptsAX = acceptsAX
        self.directory = directory; run = try .checked(directory); ticket = try readJSON(directory, "ticket.json")
        try freshness()
    }
    func freshness(_ member: Member? = nil) throws {
        try require(try Run.checked(directory) == run, "session no longer current")
        let live: OwnerState = try readJSON(directory, "owner.json")
        if run.productManagement == true, let member {
            guard let token = ticket.editTokens?[member.identifier], live.editTokens?[member.identifier] == token else {
                throw Refusal("窗口手动调整记录已变化，已停止写入")
            }
        }
        let age = ProcessInfo.processInfo.systemUptime - live.uptime
        try require(live.session == run.session && ticket.session == run.session && live.owner == ticket.owner
            && live.revision == ticket.revision && (run.productManagement == true
                ? ticket.members.allSatisfy(live.members.contains) : live.members == ticket.members), "stale enrollment")
        try require(age >= 0 && age < 2 && (run.productManagement == true
            ? live.keyOrMain == ticket.keyOrMain && live.editing != true : !live.keyOrMain && live.activations == 0), "owner inactive or focus guard tripped")
        try require(!live.members.isEmpty && live.members.count <= (run.productManagement == true ? 32 : 5) && Set(live.members.map(\.id)).count == live.members.count
            && Set(live.members.map(\.id.number)).count == live.members.count && Set(live.members.map(\.identifier)).count == live.members.count,
                    "ambiguous enrollment")
        if run.productManagement == true {
            let now = try ProcessBirth.read(live.owner.pid)
            try require(now.start == live.owner.start && live.owner.parent == run.parent.pid, "owner incarnation changed")
            try verifySiblingCode(now, name: "NearpaneFixtureWindows")
        } else { try verifyFixtureCode(live.owner, supervisor: run.parent) }
    }
    func cg(_ m: Member) throws -> Observation {
        try freshness(m)
        try require(ticket.members.contains(m) && m.id.pid == ticket.owner.pid && m.id.launch == ticket.owner.start
            && m.identifier == run.session.uuidString + "/" + m.id.element.uuidString, "wrong member incarnation")
        guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, m.id.number) as? [[String: Any]], rows.count == 1,
              let row = rows.first, row[kCGWindowNumber as String] as? UInt32 == m.id.number,
              row[kCGWindowOwnerPID as String] as? Int32 == m.id.pid, row[kCGWindowLayer as String] as? Int == 0,
              let fields = row[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: fields), rect(frame).isValid else { throw Refusal("missing exact CG owner/window") }
        return .init(member: m, cg: SurfaceRect(rect(frame)), ax: nil, onScreen: row[kCGWindowIsOnscreen as String] as? Bool == true)
    }
    func attribute(_ window: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(window, key as CFString, &value) == .success ? value : nil
    }
    func requireAccess() throws {
        try require(acceptsAX && AXIsProcessTrusted(), "Accessibility denied")
    }
    func element(_ m: Member) throws -> AXUIElement {
        try freshness(m)
        try require(ticket.members.contains(m) && m.id.pid == ticket.owner.pid && m.id.launch == ticket.owner.start
            && m.identifier == run.session.uuidString + "/" + m.id.element.uuidString, "unregistered window")
        try requireAccess()
        let app = AXUIElementCreateApplication(m.id.pid)
        AXUIElementSetMessagingTimeout(app, 0.35)
        guard let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { throw Refusal("AX inventory unavailable") }
        let matches = windows.filter { attribute($0, kAXIdentifierAttribute) as? String == m.identifier }
        guard matches.count == 1, let w = matches.first else { throw Refusal("AX identifier missing or ambiguous") }
        var pid: pid_t = 0
        try require(AXUIElementGetPid(w, &pid) == .success && pid == m.id.pid, "AX PID mismatch")
        let role = attribute(w, kAXRoleAttribute) as? String, subrole = attribute(w, kAXSubroleAttribute) as? String
        try require(role == kAXWindowRole && subrole == kAXStandardWindowSubrole, "fixture AX role \(role ?? "missing") / \(subrole ?? "missing")")
        return w
    }
    private func bound(_ m: Member) throws -> (AXUIElement, Observation) {
        let observation = try cg(m)
        let w = try element(m)
        // Some ordinary AppKit windows omit AXFullScreen. The owner heartbeat independently checks the
        // concrete NSWindow's style and miniaturization; an affirmative AX state always vetoes writes.
        try require(attribute(w, kAXModalAttribute) as? Bool != true && attribute(w, kAXMinimizedAttribute) as? Bool != true && attribute(w, "AXFullScreen") as? Bool != true,
                    "fixture minimized or fullscreen")
        guard let p = attribute(w, kAXPositionAttribute), let s = attribute(w, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { throw Refusal("AX frame values unavailable") }
        var pos = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &pos), AXValueGetValue(s as! AXValue, .cgSize, &size) else {
            throw Refusal("AX geometry unavailable")
        }
        let ax = SurfaceRect(x: pos.x, y: pos.y, width: size.width, height: size.height)
        try require(ax == observation.cg, "AX and CG disagree")
        return (w, .init(member: m, cg: observation.cg, ax: ax, onScreen: observation.onScreen))
    }
    func observe(_ m: Member) throws -> Observation { try bound(m).1 }
    func writable(_ m: Member) throws {
        let (w, _) = try bound(m)
        for key in [kAXPositionAttribute, kAXSizeAttribute] {
            var yes = DarwinBoolean(false)
            try require(AXUIElementIsAttributeSettable(w, key as CFString, &yes) == .success && yes.boolValue,
                        "required AX frame capability unavailable")
        }
    }
    func set(_ m: Member, from old: SurfaceRect, to next: SurfaceRect, parking: Bool) throws -> Observation {
        try FramePolicy.validateStep(old, next, member: m, screens: run.screens, parking: parking)
        let (window, before) = try bound(m)
        try require(before.cg == old, "frame changed since confirmation")
        var pos = CGPoint(x: next.x, y: next.y), size = CGSize(width: next.width, height: next.height)
        let moving = old.x != next.x || old.y != next.y
        let key = (moving ? kAXPositionAttribute : kAXSizeAttribute) as CFString
        let value = moving ? AXValueCreate(.cgPoint, &pos) : AXValueCreate(.cgSize, &size)
        var yes = DarwinBoolean(false)
        guard let value, AXUIElementIsAttributeSettable(window, key, &yes) == .success, yes.boolValue
        else { throw Refusal("AX attribute no longer settable") }
        if directory.deletingLastPathComponent().lastPathComponent == "WorkRect" {
            let request: CandidateLayout = try readJSON(directory, "candidate.json")
            let profile = directory.deletingLastPathComponent().deletingLastPathComponent()
            let live: HostConfiguration = try readJSON(profile, "Nearpane/host-configuration.json")
            let config = try live.validated()
            let expected = request.configuration
            func area(_ c: HostConfiguration) throws -> SurfaceRect {
                let s = run.screens
                return try DesktopWorkArea(display: s.secondary, screen: s.frame, usable: s.usable,
                    primary: c.preferredDisplayID == s.secondary, settings: c.displays[s.secondary] ?? .init(), fallbackEdge: c.edge).ordinary
            }
            try require(try area(config) == area(expected), "candidate WorkRect changed before input")
            for member in ticket.members {
                try require(try !config.workspaces.excluded(member.id, bundle: "org.nearpane.lab.NearpaneFixtureWindows"), "candidate exclusion changed before input")
            }
        }
        struct Attempt: Codable { let session: UUID, revision: Int, member: Member, before: SurfaceRect, requested: SurfaceRect }
        if run.productManagement == true {
            try validateManagementGrant(directory, session: run.session, display: run.screens.secondary)
            try require(before.onScreen, "window left the visible workspace")
        }
        let focus = run.productManagement == true ? try ManagementFocus() : nil
        try writeJSON(Attempt(session: run.session, revision: ticket.revision, member: m, before: old, requested: next),
                      directory, "attempt-" + UUID().uuidString + ".json")
        setters += 1
        let result = AXUIElementSetAttributeValue(window, key, value)
        let limit = ProcessInfo.processInfo.systemUptime + 1.2
        var last: Observation?
        repeat {
            if let seen = try? observe(m) {
                last = seen
                if seen.cg == next && result == .success { try focus?.verify(); return seen }
            }
            usleep(25_000)
        } while ProcessInfo.processInfo.systemUptime < limit
        if let last { try writeJSON(last, directory, "unconfirmed-readback.json") }
        throw Refusal("AX setter \(result.rawValue), requested frame was not confirmed by AX and CG")
    }
}

enum FramePolicy {
    static func steps(from f: SurfaceRect, to t: SurfaceRect) -> [SurfaceRect] {
        let w = min(f.width, t.width), h = min(f.height, t.height)
        let shrink = SurfaceRect(x: f.x, y: f.y, width: w, height: h)
        let move = SurfaceRect(x: t.x, y: t.y, width: w, height: h)
        var result = [SurfaceRect](), previous = f
        for next in [shrink, move, t] where next != previous { result.append(next); previous = next }
        return result
    }
    static func parkingFrame(_ f: SurfaceRect, screens s: Screens) throws -> SurfaceRect {
        let a = s.mainFrame.geometry, b = s.frame.geometry
        try require(b.intersection(f.geometry) == f.geometry, "parking origin off secondary")
        var p = f
        if b.maxX <= a.x { p.x = b.x - f.width - 2 }
        else if b.x >= a.maxX { p.x = b.maxX + 2 }
        else if b.maxY <= a.y { p.y = b.y - f.height - 2 }
        else if b.y >= a.maxY { p.y = b.maxY + 2 }
        else { throw Refusal("no secondary-only parking corridor") }
        return p
    }
    static func validateStep(_ a: SurfaceRect, _ b: SurfaceRect, member: Member, screens s: Screens, parking: Bool) throws {
        let size = a.width != b.width || a.height != b.height, move = a.x != b.x || a.y != b.y
        try require(a.geometry.isValid && b.geometry.isValid && size != move
            && b.width >= member.minimum.width && b.height >= member.minimum.height, "invalid frame or minimum size")
        if s.frame.geometry.intersection(a.geometry) == a.geometry && s.frame.geometry.intersection(b.geometry) == b.geometry { return }
        guard parking, !size else { throw Refusal("frame outside secondary") }
        if s.frame.geometry.intersection(a.geometry) == a.geometry {
            try require(try parkingFrame(a, screens: s) == b, "unapproved parking destination")
        } else {
            try require(try parkingFrame(b, screens: s) == a, "unapproved parking origin")
        }
    }
}
