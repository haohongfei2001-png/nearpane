import AppKit
import Security

// Event counts only. Pointer travel has no authority to change the foreground.
func p2Physical()->[UInt32] {
    let types:[CGEventType] = [.leftMouseDown,.rightMouseDown,.otherMouseDown,.keyDown,.scrollWheel,.keyUp,
                               .flagsChanged,.leftMouseUp,.rightMouseUp,.otherMouseUp,.leftMouseDragged,.rightMouseDragged,.otherMouseDragged]
    return types.map { CGEventSource.counterForEventType(.hidSystemState,eventType:$0) }
}

func p2TrustedObserver(_ pid:pid_t,_ birth:UInt64,_ hash:String)->Bool {
    guard pid>1,birth>0,hash.count==40,hash.allSatisfy(\.isHexDigit) else{return false}
    var process=proc_bsdinfo(),code:SecCode?,rule:SecRequirement?
    let size=Int32(MemoryLayout<proc_bsdinfo>.size)
    let requirement="identifier \"net.example.nearpane.p2-observer\" and cdhash H\""+hash+"\" and anchor apple generic and certificate leaf[subject.OU] = \"ZB9D4T66QB\""
    guard proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&process,size)==size,process.pbi_start_tvsec*1_000_000+process.pbi_start_tvusec==birth,
          SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid as String:pid] as CFDictionary,[],&code)==errSecSuccess,
          SecRequirementCreateWithString(requirement as CFString,[],&rule)==errSecSuccess,
          let code,let rule else{return false}
    return SecCodeCheckValidity(code,[],rule)==errSecSuccess
}

struct P2LaunchPresentation: Codable {
    let session:String, originalFront:pid_t, hardware:[UInt32], admittedAt:Double
    func allows(now:Double,hid:[UInt32],front:pid_t?,fixture:pid_t,mouseDown:Bool,session actual:String)->Bool {
        session==actual && UUID(uuidString:session) != nil && fixture>1 && originalFront>1 &&
        (front==originalFront || front==fixture) && !mouseDown && hardware.count==13 && hardware==hid &&
        admittedAt>0 && now>=admittedAt && now-admittedAt<8
    }
}
