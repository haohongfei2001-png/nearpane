import AppKit
import CryptoKit

@main struct MarkerTagRegression {
    static func main() {
        let marker="NP123456789a"
        let digest=SHA256.hash(data:Data(marker.utf8)).map{String(format:"%02x",$0)}.joined()
        let g=FieldMarkerGrant(session:UUID().uuidString,intent:UUID().uuidString,digest:digest,readerHash:String(repeating:"1",count:40),pid:21,birth:89,numbers:[45,46],target:46,tag:123456789,expires:100)
        precondition(g.matches(marker) && !g.matches("NP9876543210") && !g.matches(nil))
        precondition(g.bound(session:g.session,pid:21,birth:89,numbers:[45,46],now:90))
        precondition(!g.bound(session:g.session,pid:21,birth:90,numbers:[45,46],now:90))
        precondition(!g.bound(session:g.session,pid:21,birth:89,numbers:[46,45],now:90))
        precondition(!g.bound(session:g.session,pid:21,birth:89,numbers:[45,46],now:101))
        let source=CGEventSource(stateID:.privateState)!
        for down in [true,false] {
            let event=CGEvent(keyboardEventSource:source,virtualKey:0,keyDown:down)!
            let units=Array(marker.utf16)
            event.keyboardSetUnicodeString(stringLength:units.count,unicodeString:units)
            event.setIntegerValueField(.eventSourceUserData,value:g.tag)
            let restored=CGEvent(withDataAllocator:nil,data:event.data!)!
            precondition(event.getIntegerValueField(.eventSourceUserData)==g.tag)
            precondition(NSEvent(cgEvent:event)?.cgEvent?.getIntegerValueField(.eventSourceUserData)==g.tag)
            let sender=restored.getIntegerValueField(.eventSourceUnixProcessID)
            precondition(sender == Int64(getpid()))
            let poster=FieldMarkerPoster(session:g.session,intent:g.intent,digest:g.digest,hash:g.readerHash,sender:getpid(),birth:89,tag:g.tag,target:g.target,written:91)
            precondition(poster.matches(grant:g,source:sender,now:92,eventTime:0))
            precondition(!poster.matches(grant:g,source:sender+1,now:92,eventTime:0))
            precondition(!poster.matches(grant:g,source:sender,now:92,eventTime:80))
            var size=0, text=[UniChar](repeating:0,count:12)
            restored.keyboardGetUnicodeString(maxStringLength:12,actualStringLength:&size,unicodeString:&text)
            precondition(size==12 && g.matches(String(decoding:text,as:UTF16.self)))
        }
        // The synthetic events never leave this process.
        let receipt = g.receipt(status:"ARMED",events:[],truncated:false)
        FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject:receipt))
    }
}
