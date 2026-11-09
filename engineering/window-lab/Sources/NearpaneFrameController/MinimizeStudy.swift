import AppKit
import NearpaneCore
import WindowLab

struct VisibilitySample: Codable, Equatable {
    let member: Member, minimized: Bool, settable: Bool, onscreen: Bool
    let frame: SurfaceRect?
}
struct VisibilityLog: Codable {
    let run: UUID, transaction: UUID, peer: ProcessBirth, revision: Int
    let original: [VisibilitySample]
    var confirmed: [Bool], pendingIndex: Int?, pendingValue: Bool?, settled: Bool
}
@MainActor final class MinimizeStudy {
    let a: FixtureAdapter, files: SessionFiles
    init(_ dir: URL) throws {
        a = try FixtureAdapter(dir); files = try SessionFiles(dir)
        try require(a.run.parkingStudy == true, "visibility experiment not enrolled")
    }
    func read(_ m: Member) throws -> VisibilitySample {
        let w = try a.element(m)
        var settable = DarwinBoolean(false)
        guard let mini = a.attribute(w,kAXMinimizedAttribute) as? Bool,
              AXUIElementIsAttributeSettable(w,kAXMinimizedAttribute as CFString,&settable) == .success,
              let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow,m.id.number) as? [[String:Any]],
              rows.count <= 1 else { throw Refusal("minimization observation unavailable") }
        var frame: SurfaceRect?, onscreen = false
        if let row = rows.first {
            try require(row[kCGWindowOwnerPID as String] as? Int32 == m.id.pid && row[kCGWindowNumber as String] as? UInt32 == m.id.number,
                        "CG incarnation changed")
            if let d = row[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation:d) { frame = SurfaceRect(rect(r)) }
            onscreen = row[kCGWindowIsOnscreen as String] as? Bool == true
        }
        if !mini { let o = try a.observe(m); try require(frame == o.ax && onscreen, "restored frame not visible") }
        return .init(member:m,minimized:mini,settable:settable.boolValue,onscreen:onscreen,frame:frame)
    }
    func all() throws -> [VisibilitySample] { try a.ticket.members.map(read) }
    func dock() throws -> SurfaceRect {
        try secondaryDock(a.run.screens)
    }
    func perform(_ verb:String) throws -> [VisibilitySample] {
        let members=a.ticket.members, before=try all()
        if verb=="mini-read" { return before }
        let path="visibility.json"
        try require(verb == "mini-recover", "real Virtual parking is unavailable")
        guard var j: VisibilityLog = try files.load(path) else { throw Refusal("no admitted visibility transaction") }
        try require(j.run==a.run.session && j.peer==a.ticket.owner && j.revision==a.ticket.revision && j.original.map(\.member)==members
                    && j.confirmed.count==members.count, "visibility journal owner changed")
        for i in members.indices {
            let b=before[i]
            try require(b.minimized==j.confirmed[i] || (j.pendingIndex==i && j.pendingValue==b.minimized), "window state changed")
            try require(b.minimized ? !b.onscreen : b.frame==j.original[i].frame, "visibility or layout conflict")
        }
        for i in members.indices {
            let m=members[i], old=before[i].minimized
            let next = j.original[i].minimized
            try require(!next, "invalid visibility recovery origin")
            if next != old {
                try require(m.index<=2 && before[i].settable, "minimize unsupported or excluded")
                let dockFrame = try dock()
                j.pendingIndex=i; j.pendingValue=next; try files.persist(j,path)
                let w=try a.element(m)
                try require(try read(m)==before[i], "window changed before minimize setter")
                let t=ProcessInfo.processInfo.systemUptime
                let rc=AXUIElementSetAttributeValue(w,kAXMinimizedAttribute as CFString,next ? kCFBooleanTrue : kCFBooleanFalse)
                struct Attempt:Codable { let uptime:Double, member:Member, minimize:Bool, result:Int32, dock:SurfaceRect }
                try files.persist(Attempt(uptime:t,member:m,minimize:next,result:rc.rawValue,dock:dockFrame),"mini-attempt-"+UUID().uuidString+".json")
                var confirmed=false
                repeat {
                    if let r=try? read(m), r.minimized==next && r.onscreen != next && (next || r.frame==j.original[i].frame) { confirmed=true; break }
                    usleep(30_000)
                } while ProcessInfo.processInfo.systemUptime-t<1.8
                try require(confirmed && rc == .success, "mini setter or independent readback failed")
                j.confirmed[i]=next; j.pendingIndex=nil; j.pendingValue=nil; try files.persist(j,path)
            }
        }
        let final=try all()
        for i in members.indices {
            let wanted = j.original[i].minimized
            try require(final[i].minimized==wanted && final[i].onscreen != wanted && (wanted || final[i].frame==j.original[i].frame),"group failed verification")
        }
        j.confirmed=final.map(\.minimized); j.pendingIndex=nil; j.pendingValue=nil; j.settled=true
        try files.persist(j,path); return final
    }
}

@MainActor func secondaryDock(_ screens: Screens) throws -> SurfaceRect {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.dock")
        guard apps.count == 1, let pid = apps.first?.processIdentifier else { throw Refusal("Dock owner unknown") }
        let app = AXUIElementCreateApplication(pid)
        let lists = (labAttribute(app,kAXChildrenAttribute) as? [AXUIElement])?.filter { labAttribute($0,kAXRoleAttribute) as? String == kAXListRole }
        guard lists?.count == 1, let list = lists?.first, let p = labAttribute(list,kAXPositionAttribute), let sz = labAttribute(list,kAXSizeAttribute),
              CFGetTypeID(p)==AXValueGetTypeID(), CFGetTypeID(sz)==AXValueGetTypeID() else { throw Refusal("Dock location unknown") }
        var xy=CGPoint.zero, size=CGSize.zero
        guard AXValueGetValue(p as! AXValue,.cgPoint,&xy), AXValueGetValue(sz as! AXValue,.cgSize,&size) else { throw Refusal("invalid Dock frame") }
        let r=CGRect(origin:xy,size:size), s=screens.frame, primary=screens.mainFrame
        // Restrict this device experiment to the observed left-edge Dock on the outer secondary edge.
        try require(r.width>0 && r.height>0 && s.x+s.width<=primary.x && r.minX<=s.x && r.maxX>=s.x && r.maxX<s.x+s.width
            && r.minY>=s.y && r.maxY<=s.y+s.height, "Dock destination not confined to secondary")
        return SurfaceRect(rect(r))
    }
