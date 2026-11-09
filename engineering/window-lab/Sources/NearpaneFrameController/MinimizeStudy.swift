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
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.dock")
        guard apps.count == 1, let pid = apps.first?.processIdentifier else { throw Refusal("Dock owner unknown") }
        let app = AXUIElementCreateApplication(pid)
        let lists = (a.attribute(app,kAXChildrenAttribute) as? [AXUIElement])?.filter { a.attribute($0,kAXRoleAttribute) as? String == kAXListRole }
        guard lists?.count == 1, let list = lists?.first, let p = a.attribute(list,kAXPositionAttribute), let sz = a.attribute(list,kAXSizeAttribute),
              CFGetTypeID(p)==AXValueGetTypeID(), CFGetTypeID(sz)==AXValueGetTypeID() else { throw Refusal("Dock location unknown") }
        var xy=CGPoint.zero, size=CGSize.zero
        guard AXValueGetValue(p as! AXValue,.cgPoint,&xy), AXValueGetValue(sz as! AXValue,.cgSize,&size) else { throw Refusal("invalid Dock frame") }
        let r=CGRect(origin:xy,size:size), s=a.run.screens.frame, primary=a.run.screens.mainFrame
        // Restrict this device experiment to the observed left-edge Dock on the outer secondary edge.
        try require(r.width>0 && r.height>0 && s.x+s.width<=primary.x && r.minX<=s.x && r.maxX>=s.x && r.maxX<s.x+s.width
            && r.minY>=s.y && r.maxY<=s.y+s.height, "Dock destination not confined to secondary")
        return SurfaceRect(rect(r))
    }
    func perform(_ verb:String) throws -> [VisibilitySample] {
        let members=a.ticket.members, before=try all()
        if verb=="mini-read" { return before }
        let path="visibility.json"
        let frameLog:FrameJournal? = try files.load("journal.json")
        try require(frameLog == nil || frameLog?.status == .restored || frameLog?.status == .retained, "frame recovery pending")
        var j:VisibilityLog
        if let saved:VisibilityLog = try files.load(path), !saved.settled || verb=="mini-recover" {
            j=saved
        } else {
            try require(before.allSatisfy { !$0.minimized && $0.onscreen && $0.frame != nil }, "initial windows not visible")
            j = .init(run:a.run.session,transaction:UUID(),peer:a.ticket.owner,revision:a.ticket.revision,original:before,
                      confirmed:before.map(\.minimized),pendingIndex:nil,pendingValue:nil,settled:false)
        }
        try require(j.run==a.run.session && j.peer==a.ticket.owner && j.revision==a.ticket.revision && j.original.map(\.member)==members
                    && j.confirmed.count==members.count, "visibility journal owner changed")
        let recovering = verb=="mini-recover"
        if !recovering { try require(j.pendingIndex==nil, "visibility recovery required") }
        for i in members.indices {
            let b=before[i]
            try require(b.minimized==j.confirmed[i] || (j.pendingIndex==i && j.pendingValue==b.minimized), "window state changed")
            try require(b.minimized ? !b.onscreen : b.frame==j.original[i].frame, "visibility or layout conflict")
        }
        for i in members.indices {
            let m=members[i], old=before[i].minimized
            let next = !recovering && ((verb=="mini-B" || verb=="mini-kill-park") ? m.index==1 : m.index==2)
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
                if verb=="mini-kill-park" || (verb=="mini-kill-restore" && !next) {
                    try files.persist(try all(),"mini-death.json")
                    while getppid()==a.run.parent.pid && ProcessInfo.processInfo.systemUptime<a.run.deadline { usleep(100_000) }
                    throw Refusal("death checkpoint expired")
                }
                j.confirmed[i]=next; j.pendingIndex=nil; j.pendingValue=nil; try files.persist(j,path)
            }
        }
        let final=try all()
        for i in members.indices {
            let wanted = !recovering && ((verb=="mini-B" || verb=="mini-kill-park") ? members[i].index==1 : members[i].index==2)
            try require(final[i].minimized==wanted && final[i].onscreen != wanted && (wanted || final[i].frame==j.original[i].frame),"group failed verification")
        }
        j.confirmed=final.map(\.minimized); j.pendingIndex=nil; j.pendingValue=nil; j.settled=recovering
        try files.persist(j,path); return final
    }
}
