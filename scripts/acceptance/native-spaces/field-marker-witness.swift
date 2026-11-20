import AppKit
import CryptoKit

// Only compiled into the optional Field Notes fixture. No system event tap.
struct FieldMarkerGrant: Codable, Equatable {
    let session: String, intent: String, digest: String, readerHash: String
    let pid: Int32, birth: UInt64, numbers: [Int], target: Int, tag: Int64, expires: Double
    func bound(session actual: String, pid current: Int32, birth generation: UInt64, numbers live: [Int], now: Double) -> Bool {
        session == actual && UUID(uuidString:intent) != nil && pid == current && birth == generation &&
        numbers == live && live.count == 2 && Set(live).count == 2 && live.allSatisfy { $0 > 0 } && live.contains(target) &&
        tag > 0 && expires > now && expires-now <= 15 && digest.utf8.count == 64 &&
        readerHash.utf8.count == 40 && readerHash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } &&
        digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    func matches(_ text: String?) -> Bool {
        guard let text, text.utf8.count == 12, text.hasPrefix("NP") else { return false }
        return SHA256.hash(data:Data(text.utf8)).map { String(format:"%02x",$0) }.joined() == digest
    }
    func receipt(status: String, events: [[String: Any]], truncated: Bool) -> [String: Any] {
        ["session": session, "intent": intent, "digest": digest, "readerHash": readerHash,
         "pid": pid, "birth": birth, "numbers": numbers, "target": target,
         "status": status, "events": events, "truncated": truncated]
    }
}
struct FieldMarkerPoster: Decodable {
    let session:String, intent:String, digest:String, hash:String, sender:Int32, birth:UInt64, tag:Int64, target:Int, written:Double
    func matches(grant:FieldMarkerGrant, source:Int64, now:Double, eventTime:Double) -> Bool {
        session == grant.session && intent == grant.intent && digest == grant.digest && hash == grant.readerHash &&
        Int64(sender) == source && sender > 1 && birth > 0 && tag == grant.tag && target == grant.target &&
        written >= grant.expires-15 && written <= now && now < grant.expires &&
        (eventTime == 0 || eventTime >= written-0.010 && eventTime <= now+0.010)
    }
}
private struct FieldMarkerCommand: Decodable { let mode: String, grant: FieldMarkerGrant }

@MainActor final class FieldMarkerWitness {
    static var active: FieldMarkerWitness?
    let folder: URL, session: String, pid: pid_t, birth: UInt64
    private let objects: () -> ([NSWindow],[NSTextView])
    private var grant: FieldMarkerGrant?
    private var finished = Set<String>()
    private var events = [[String:Any]]()
    private var status = "", dirty = false, truncated = false, dispatching = false
    private var monitor: Any?
    private var poster: FieldMarkerPoster?
    private var attribution: String?

    init?(folder: URL, session: String, birth: UInt64, objects: @escaping () -> ([NSWindow],[NSTextView])) {
        guard ProcessInfo.processInfo.environment["NP_W01_MARKER_WITNESS"] == "1",
              Bundle.main.bundleIdentifier == "net.example.spaces-document", UUID(uuidString:session) != nil,
              folder.lastPathComponent == session else { return nil }
        func physical(_ url: URL) -> String? {
            guard let path = realpath(url.path,nil) else { return nil }; defer {free(path)}; return String(cString:path)
        }
        let kit = folder.deletingLastPathComponent()
        func privateDirectory(_ url: URL) -> Bool {
            var node = stat(); return lstat(url.path,&node) == 0 && node.st_uid == getuid() &&
                node.st_mode & S_IFMT == S_IFDIR && node.st_mode & 0o077 == 0
        }
        guard privateDirectory(folder), privateDirectory(kit),
              kit.lastPathComponent.hasPrefix("nearpane-d01.") || kit.lastPathComponent.hasPrefix("nearpane-wp5."),
              physical(folder) == "/private/tmp/"+kit.lastPathComponent+"/"+session else { return nil }
        self.folder=folder; self.session=session; self.pid=getpid(); self.birth=birth; self.objects=objects
    }
    private func read<T:Decodable>(_ name:String, as type:T.Type) -> T? {
        let fd = open(folder.appendingPathComponent(name).path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let file = FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        var node = stat()
        guard fstat(fd,&node) == 0, node.st_uid == getuid(), node.st_mode & S_IFMT == S_IFREG, node.st_mode & 0o077 == 0,
              node.st_nlink == 1, (1...2048).contains(node.st_size), let data = try? file.read(upToCount:2049),
              data.count == node.st_size else { return nil }
        return try? JSONDecoder().decode(type,from:data)
    }
    private func snapshot() -> [String:Any] {
        let (windows,editors) = objects()
        func scoped(_ n: Int) -> Int { (grant?.numbers.contains(n) ?? false) ? n : n == 0 ? 0 : -1 }
        return ["clock":ProcessInfo.processInfo.systemUptime, "key":scoped(NSApp.keyWindow?.windowNumber ?? 0),
                "main":scoped(NSApp.mainWindow?.windowNumber ?? 0), "active":NSApp.isActive,
                "responders":zip(windows,editors).map { $0.firstResponder === $1 }, "marked":editors.map { $0.hasMarkedText() }]
    }
    private func note(_ step: String, event: NSEvent? = nil, window: NSWindow? = nil, match: Bool? = nil) {
        guard let grant, status == "ARMED" else { return }
        guard events.count < 64 else { truncated=true; dirty=true; return }
        var value=snapshot(); value["step"]=step
        if let event {
            let number=event.windowNumber
            value["eventWindow"] = grant.numbers.contains(number) ? number : number == 0 ? 0 : -1
            value["eventClock"] = event.timestamp
        }
        if let window { value["receiver"] = grant.numbers.contains(window.windowNumber) ? window.windowNumber : -1 }
        if let match { value["markerMatches"] = match }
        if let attribution { value["attribution"] = attribution }
        events.append(value); dirty=true
    }
    private func provenance(_ event:NSEvent) -> String? {
        let now=ProcessInfo.processInfo.systemUptime
        guard let grant, status == "ARMED", now < grant.expires, event.type == .keyDown || event.type == .keyUp,
              let cg=event.cgEvent else { return nil }
        let tag=cg.getIntegerValueField(.eventSourceUserData)
        if tag == grant.tag { return "eventTag" }
        guard tag == 0 else { return nil }
        let source=cg.getIntegerValueField(.eventSourceUnixProcessID)
        guard source > 1 && source <= Int64(Int32.max) else { return nil }
        if poster == nil { poster=read("marker-watch-poster-"+grant.intent+".json",as:FieldMarkerPoster.self) }
        guard let poster, poster.matches(grant:grant,source:source,now:now,eventTime:event.timestamp) else { return nil }
        var info=proc_bsdinfo()
        let size=Int32(MemoryLayout<proc_bsdinfo>.size)
        let ret=proc_pidinfo(poster.sender,PROC_PIDTBSDINFO,0,&info,size)
        if ret == size {
            guard info.pbi_start_tvsec*1_000_000+info.pbi_start_tvusec == poster.birth else { return nil }
        } else if ret != 0 || errno != ESRCH { return nil }
        // A serialized Quartz event can lose userData. Only inspect text from the attested one-shot sender.
        return grant.matches(event.characters) ? "signedSenderAndDigest" : nil
    }
    func appEvent(_ event: NSEvent) {
        guard let origin=provenance(event), let grant else { return }
        let prior=attribution; attribution=origin; defer { attribution=prior }
        note(event.type == .keyDown ? "appKeyDown":"appKeyUp",event:event,match:grant.matches(event.characters))
    }
    // Always invoke normal dispatch once, including for every untagged event.
    func dispatch(_ event: NSEvent, window: NSWindow?, editor: Bool, _ deliver: () -> Void) {
        let prior=dispatching, oldOrigin=attribution
        attribution=provenance(event); dispatching=attribution != nil
        defer { dispatching=prior; attribution=oldOrigin }
        if dispatching, let grant {
            note((editor ? "editor":"window") + (event.type == .keyDown ? "KeyDown":"KeyUp"),event:event,window:window,match:grant.matches(event.characters))
        }
        deliver()
    }
    func text(_ step: String, editor: NSTextView, _ value: Any?) {
        // A delayed, untagged input-method callback has no proven origin.
        guard dispatching, let grant, status == "ARMED", ProcessInfo.processInfo.systemUptime < grant.expires else { return }
        let text = value as? String ?? (value as? NSAttributedString)?.string
        note(step,window:editor.window,match:value == nil ? nil : grant.matches(text))
    }
    private func end(_ state: String) {
        guard let grant, status == "ARMED" else { return }
        note("end")
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor=nil }
        dispatching=false; finished.insert(grant.intent); status=state; dirty=true
    }
    func tick(final: Bool = false) {
        let now=ProcessInfo.processInfo.systemUptime
        if final { end("EXITED") }
        else if let grant, status == "ARMED", now >= grant.expires { end("EXPIRED") }
        else if let cmd=read("marker-watch-command.json",as:FieldMarkerCommand.self) {
            let (windows,editors)=objects()
            if cmd.mode == "seal", cmd.grant == grant { end("SEALED") }
            else if cmd.mode == "arm", status != "ARMED", finished.count < 10, !finished.contains(cmd.grant.intent), editors.count == 2,
                    cmd.grant.bound(session:session,pid:pid,birth:birth,numbers:windows.map(\.windowNumber),now:now) {
                grant=cmd.grant; status="ARMED"; events=[]; truncated=false; poster=nil; attribution=nil
                // A local monitor only exists during this one enrolled marker. It forwards its input verbatim.
                monitor=NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.keyUp]) { [weak self] e in
                    MainActor.assumeIsolated { self?.appEvent(e) }; return e
                }
                if monitor == nil { end("UNAVAILABLE") } else { note("arm") }
            }
        }
        guard dirty, let grant else { return }
        let data=grant.receipt(status:status,events:events,truncated:truncated)
        let output=folder.appendingPathComponent("marker-watch-response.json")
        do {
            try JSONSerialization.data(withJSONObject:data).write(to:output,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:output.path)
            dirty=false
        } catch { return }
    }
}

@MainActor final class MarkerWitnessWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        guard let witness=FieldMarkerWitness.active else { super.sendEvent(event); return }
        witness.dispatch(event,window:self,editor:false) { super.sendEvent(event) }
    }
}
@MainActor final class MarkerWitnessEditor: NSTextView {
    override func keyDown(with event:NSEvent) {
        guard let w=FieldMarkerWitness.active else { super.keyDown(with:event); return }
        w.dispatch(event,window:window,editor:true) { super.keyDown(with:event) }
    }
    override func keyUp(with event:NSEvent) {
        guard let w=FieldMarkerWitness.active else { super.keyUp(with:event); return }
        w.dispatch(event,window:window,editor:true) { super.keyUp(with:event) }
    }
    override func insertText(_ string: Any, replacementRange: NSRange) {
        FieldMarkerWitness.active?.text("insertText",editor:self,string)
        super.insertText(string,replacementRange:replacementRange)
        FieldMarkerWitness.active?.text("afterInsert",editor:self,nil)
    }
    override func setMarkedText(_ string:Any, selectedRange:NSRange, replacementRange:NSRange) {
        FieldMarkerWitness.active?.text("setMarkedText",editor:self,string)
        super.setMarkedText(string,selectedRange:selectedRange,replacementRange:replacementRange)
        FieldMarkerWitness.active?.text("afterMarked",editor:self,nil)
    }
    override func unmarkText() {
        FieldMarkerWitness.active?.text("unmarkText",editor:self,nil)
        super.unmarkText()
    }
}
