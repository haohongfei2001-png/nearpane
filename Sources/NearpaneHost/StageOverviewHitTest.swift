import AppKit
import ApplicationServices
import CryptoKit
import Security

/// Public AX position probes. Coordinates use the top-left origin of the main display, in points.
@MainActor enum StageOverviewHitTest {
    typealias Row = [String: Any]

    struct Tile: Equatable {
        let element: AXUIElement
        let frame: CGRect

        static func == (lhs: Self, rhs: Self) -> Bool {
            CFEqual(lhs.element, rhs.element) && lhs.frame == rhs.frame
        }
    }

    struct Sample {
        let tiles: [Tile]
        let evidence: Row
        let complete: Bool
    }

    static func positions(in bounds: CGRect) -> [CGPoint] {
        let columns = min(40, max(12, Int(ceil(bounds.width / 44))))
        return [32.0, 64, 100, 16, 136].filter { $0 < bounds.height * 0.24 }.flatMap { y in
            (0..<columns).map { i in
                CGPoint(x: bounds.minX + (CGFloat(i) + 0.5) * bounds.width / CGFloat(columns), y: bounds.minY + y)
            }
        }
    }

    static func validLayout(_ rects: [CGRect], in bounds: CGRect) -> Bool {
        guard !rects.isEmpty, rects.allSatisfy({ !$0.isEmpty && bounds.contains($0) }),
              let first = rects.first else { return false }
        return rects.allSatisfy { $0.minY < first.maxY && $0.maxY > first.minY } &&
            zip(rects,rects.dropFirst()).allSatisfy { $0.maxX <= $1.minX }
    }

    static func box(_ rect: CGRect) -> [Double] { [rect.minX, rect.minY, rect.width, rect.height] }

    private static func value(_ item: AXUIElement, _ key: String) -> (AXError, CFTypeRef?) {
        var v: CFTypeRef?
        let rc = AXUIElementCopyAttributeValue(item, key as CFString, &v)
        return (rc, v)
    }

    private static func publicID(_ id: String?, system: Bool) -> Any {
        guard let id else { return NSNull() }
        if system && (id == "mc" || id.hasPrefix("mc.")) && id.range(of: #"^[a-zA-Z0-9._-]{1,96}$"#, options:.regularExpression) != nil { return id }
        return "sha256-" + SHA256.hash(data: Data(id.utf8)).prefix(10).map { String(format:"%02x",$0) }.joined()
    }

    private struct Node {
        let pid: pid_t
        let role: String?
        let id: String?
        let frame: CGRect?
        let row: Row

        @MainActor init(_ item: AXUIElement, owners: Set<pid_t>) {
            var owner: pid_t = 0
            let pidError = AXUIElementGetPid(item, &owner)
            let (r, roleValue) = value(item,kAXRoleAttribute), (i, name) = value(item,kAXIdentifierAttribute)
            let (p, position) = value(item,kAXPositionAttribute), (s, size) = value(item,kAXSizeAttribute)
            var point = CGPoint.zero, extent = CGSize.zero
            let valid = position.map { CFGetTypeID($0) == AXValueGetTypeID() && AXValueGetValue($0 as! AXValue,.cgPoint,&point) } == true &&
                size.map { CFGetTypeID($0) == AXValueGetTypeID() && AXValueGetValue($0 as! AXValue,.cgSize,&extent) } == true &&
                [point.x,point.y,extent.width,extent.height].allSatisfy(\.isFinite)
            pid = owner
            role = roleValue as? String
            id = name as? String
            frame = valid ? CGRect(origin:point,size:extent) : nil
            row = ["pid":pidError == .success ? Int(owner) as Any : NSNull(), "role":role as Any? ?? NSNull(),
                   "identifier":publicID(id,system:owners.contains(owner)), "frame":frame.map(box) as Any? ?? NSNull(),
                   "errors":["pid":pidError.rawValue,"role":r.rawValue,"identifier":i.rawValue,"position":p.rawValue,"size":s.rawValue]]
        }
    }

    private static func systemOwners(dockPID: pid_t) -> Set<pid_t> {
        var result: Set<pid_t> = [dockPID]
        let id = "com.apple.WindowManager"
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier:id)
        var rule: SecRequirement?, code: SecCode?
        if apps.count == 1, let app = apps.first,
           app.executableURL?.path == "/System/Library/CoreServices/WindowManager.app/Contents/MacOS/WindowManager",
           SecRequirementCreateWithString("anchor apple and identifier \"com.apple.WindowManager\"" as CFString, [], &rule) == errSecSuccess,
           let rule, SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid as String:app.processIdentifier] as CFDictionary,[],&code) == errSecSuccess,
           let code, SecCodeCheckValidity(code,[],rule) == errSecSuccess { result.insert(app.processIdentifier) }
        return result
    }

    static func sample(dock: AXUIElement, dockPID: pid_t, bounds: CGRect, inputUnchanged: () -> Bool) -> Sample {
        let sys = AXUIElementCreateSystemWide(), owners = systemOwners(dockPID:dockPID)
        let start = ProcessInfo.processInfo.systemUptime
        let timeout: Float = 0.10
        let dockTimeout = AXUIElementSetMessagingTimeout(dock,timeout), systemTimeout = AXUIElementSetMessagingTimeout(sys,timeout)
        var indexes = [AXUIElement:Int](), nodes = [Node](), parent = [AXUIElement:AXUIElement]()
        var noParent = Set<AXUIElement>(), measured = [AXUIElement:Tile](), observations = [Row]()
        let points = positions(in:bounds)
        var conflicting = false
        func index(_ ax: AXUIElement) -> Int {
            if let prior = indexes[ax] { return prior }
            let next = nodes.count
            indexes[ax] = next
            nodes.append(Node(ax,owners:owners))
            return next
        }
        func parentOf(_ item: AXUIElement) -> AXUIElement? {
            if let stored = parent[item] { return stored }
            guard !noParent.contains(item) else { return nil }
            let (rc,v) = value(item,kAXParentAttribute)
            guard rc == .success, let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { noParent.insert(item); return nil }
            let next = v as! AXUIElement
            parent[item] = next
            return next
        }
        func tile(_ hit: AXUIElement, at point: CGPoint) -> Tile? {
            var item = hit, seen = Set<AXUIElement>()
            for _ in 0..<8 {
                let node = nodes[index(item)]
                guard owners.contains(node.pid), seen.insert(item).inserted else { return nil }
                if node.role == kAXButtonRole, let rect = node.frame, bounds.contains(rect), rect.contains(point) {
                    // A fullscreen window, a desktop icon and the Add/Remove buttons each have distinct AX identities.
                    if node.id == "mc.spaces.space" { return Tile(element:item,frame:rect) }
                    if let container = parentOf(item) {
                        let list = nodes[index(container)]
                        if list.id == "mc.spaces.list", list.pid == node.pid, let area = list.frame,
                           area.contains(rect), !["mc.spaces.add","mc.spaces.remove"].contains(node.id ?? "") {
                            return Tile(element:item,frame:rect)
                        }
                    }
                }
                guard let next = parentOf(item) else { return nil }
                item = next
            }
            return nil
        }
        var interrupted = false
        scan: for point in points {
            guard inputUnchanged() else { interrupted = true; break }
            if ProcessInfo.processInfo.systemUptime - start >= 2.0 || dockTimeout != .success || systemTimeout != .success { break }
            var row: Row = ["point":[point.x,point.y]]
            var dockTile: Tile?
            for (label,root) in [("dock",dock),("systemWide",sys)] {
                guard inputUnchanged() else {
                    interrupted = true
                    if row["dock"] != nil { observations.append(row) }
                    break scan
                }
                var hit: AXUIElement?
                let error = AXUIElementCopyElementAtPosition(root,Float(point.x),Float(point.y),&hit)
                var actual: Row = ["axError":error.rawValue]
                if error == .success, let hit {
                    actual["object"] = index(hit)
                    if let found = tile(hit,at:point) {
                        actual["tile"] = index(found.element)
                        if label == "dock" { dockTile = found }
                        else {
                            measured[found.element] = found
                            if let dockTile, dockTile != found { conflicting = true }
                        }
                    }
                }
                row[label] = actual
            }
            observations.append(row)
        }
        if !inputUnchanged() { interrupted = true }
        let sorted = measured.values.sorted { $0.frame.midX < $1.frame.midX }
        let complete = observations.count == points.count && !conflicting && !interrupted
        let evidence: Row = ["startUptime":start,"endUptime":ProcessInfo.processInfo.systemUptime,
            "displayFrame":box(bounds),"targetPoints":points.count,"pointsRead":observations.count,
            "rootTimeoutErrors":["dock":dockTimeout.rawValue,"systemWide":systemTimeout.rawValue],
            "inputInterrupted":interrupted,"rootDisagreement":conflicting,"objects":nodes.map(\.row),"hits":observations,
            "visibleTiles":sorted.map { ["object":index($0.element),"frame":box($0.frame)] as Row },
            "completeGrid":complete]
        return Sample(tiles:sorted,evidence:evidence,complete:complete)
    }
}
