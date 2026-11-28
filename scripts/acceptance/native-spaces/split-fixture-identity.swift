import Foundation
import Security

func splitRealPath(_ text: String) -> String? {
    guard let path=realpath(text,nil) else{return nil}
    defer{free(path)}
    return String(cString:path)
}
func splitProcessPath(_ pid:pid_t) -> String? {
    var bytes=[CChar](repeating:0,count:4096)
    guard proc_pidpath(pid,&bytes,UInt32(bytes.count))>0 else{return nil}
    return splitRealPath(String(cString:bytes))
}
func splitSignedPID(_ pid:pid_t, identifier:String) -> Bool {
    var code:SecCode?,requirement:SecRequirement?
    let rule="identifier \"" + identifier + "\""
    return SecRequirementCreateWithString(rule as CFString,[],&requirement)==errSecSuccess && requirement != nil &&
        SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid:NSNumber(value:pid)] as CFDictionary,[],&code)==errSecSuccess &&
        code.map{SecCodeCheckValidity($0,[],requirement)==errSecSuccess}==true
}
func splitFixturePath(_ requested:String,observerExecutable:String) -> String? {
    guard let observer=splitRealPath(observerExecutable) else{return nil}
    let kit=URL(fileURLWithPath:observer).deletingLastPathComponent()
    let expected=kit.appendingPathComponent("Split Notes.app/Contents/MacOS/SplitNotes").path
    var metadata=stat()
    guard kit.deletingLastPathComponent().path=="/private/tmp",kit.lastPathComponent.hasPrefix("nearpane-d01."),
          lstat(kit.path,&metadata)==0,metadata.st_uid==getuid(),metadata.st_mode & 0o177777 == 0o40700,
          splitRealPath(requested)==expected,splitRealPath(expected)==expected else{return nil}
    return expected
}
