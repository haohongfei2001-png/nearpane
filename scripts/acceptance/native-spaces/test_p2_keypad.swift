import AppKit
import CryptoKit

@main struct P2KeypadTests {
    static func main() {
        let marker="012345678951"
        let expected=P2Keypad.keys(marker)!
        precondition(expected == [0x52,0x53,0x54,0x55,0x56,0x57,0x58,0x59,0x5b,0x5c,0x57,0x53])
        precondition(P2Keypad.keys("NP123456789a")==nil && P2Keypad.keys("123")==nil)
        let source=CGEventSource(stateID:.privateState)!
        var seen=P2KeyCounts()
        seen.posterBound=true
        for (i,key) in expected.enumerated() {
            let events=P2Keypad.pair(key,source:source,tag:71923)!
            for event in [events.0,events.1] {
                precondition(event.getIntegerValueField(.keyboardEventKeycode)==Int64(key))
                precondition(event.getIntegerValueField(.eventSourceUserData)==71923 && event.flags.contains(.maskNumericPad))
                precondition(event.getIntegerValueField(.eventSourceUnixProcessID)==Int64(getpid()))
            }
            seen.saw(down:true,trustedKey:key);seen.saw(down:false,trustedKey:key)
            precondition(seen.matchesReceivedPrefix(String(marker.prefix(i+1))))
        }
        let digest=SHA256.hash(data:Data(marker.utf8)).map{String(format:"%02x",$0)}.joined()
        precondition(seen.report(expected:digest)["sequenceMatches"] as? Bool==true)
        seen.saw(down:true,trustedKey:nil)
        precondition(seen.report(expected:digest)["unattributedDown"] as? Int==1)
        seen.superseded=true
        precondition(!seen.matchesReceivedPrefix("012"))
        let out=try! JSONSerialization.data(withJSONObject:seen.report(expected:digest))
        precondition(!String(decoding:out,as:UTF8.self).contains(marker))
        FileHandle.standardOutput.write(out)
    }
}
