import CoreGraphics
import Darwin
import Foundation
import Security

enum PairSystemCursor {
    static let path = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer"
    private static func birth(_ pid: pid_t, uid: uid_t) -> UInt64? {
        // PROC_PIDTBSDINFO can return EPERM for the real _windowserver service.
        // KERN_PROC_PID publishes its kernel birth and UID without a task port.
        var mib = [CTL_KERN,KERN_PROC,KERN_PROC_PID,pid], info = kinfo_proc(), length = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib,4,&info,&length,nil,0)==0, length == MemoryLayout<kinfo_proc>.stride,
              info.kp_proc.p_pid == pid, info.kp_eproc.e_ucred.cr_uid == uid else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        guard start.tv_sec > 0, start.tv_usec >= 0 else { return nil }
        return UInt64(start.tv_sec)*1_000_000+UInt64(start.tv_usec)
    }

    static func generation(_ pid: pid_t) -> UInt64? {
        var bytes = [CChar](repeating:0,count:4096)
        guard pid > 1, let account = getpwnam("_windowserver") else { return nil }
        let uid = account.pointee.pw_uid
        guard let original = birth(pid,uid:uid), proc_pidpath(pid,&bytes,UInt32(bytes.count))>0,
              String(cString:bytes)==path else { return nil }
        var guest: SecCode?, rule: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple and identifier \"com.apple.WindowServer\"" as CFString,[],&rule)==errSecSuccess,
              let rule, SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid as String:pid] as CFDictionary,[],&guest)==errSecSuccess,
              let guest,SecCodeCheckValidity(guest,[],rule)==errSecSuccess else { return nil }
        return birth(pid,uid:uid) == original ? original : nil
    }

    static func footprint(_ bounds: CGRect, cursor: CGPoint?, candidate: CGPoint) -> Bool {
        guard let cursor else { return false }
        return bounds.width >= 1 && bounds.height >= 1 && bounds.width <= 180 && bounds.height <= 180 &&
            bounds.contains(candidate) && bounds.insetBy(dx:-1,dy:-1).contains(cursor)
    }
}
