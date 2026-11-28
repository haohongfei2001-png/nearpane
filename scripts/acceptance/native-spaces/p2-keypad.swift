import AppKit
import CryptoKit

enum P2Keypad {
    static let transport = "pidNumericKeypad"
    // Carbon HIToolbox/Events.h kVK_ANSI_Keypad0 ... kVK_ANSI_Keypad9.
    static let codes: [CGKeyCode] = [0x52,0x53,0x54,0x55,0x56,0x57,0x58,0x59,0x5b,0x5c]

    static func keys(_ text: String) -> [CGKeyCode]? {
        let bytes = Array(text.utf8)
        guard bytes.count == 12, bytes.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return bytes.map { codes[Int($0 - 48)] }
    }

    static func pair(_ key: CGKeyCode, source: CGEventSource, tag: Int64) -> (CGEvent,CGEvent)? {
        guard codes.contains(key), tag > 0, let down=CGEvent(keyboardEventSource:source,virtualKey:key,keyDown:true),
              let up=CGEvent(keyboardEventSource:source,virtualKey:key,keyDown:false) else { return nil }
        for event in [down,up] {
            event.flags = .maskNumericPad
            event.setIntegerValueField(.eventSourceUserData,value:tag)
            guard event.getIntegerValueField(.eventSourceUserData)==tag else { return nil }
        }
        return (down,up)
    }
}

// Only exact tagged events or events from the registered live sender supply key codes.
// Unattributed local events supply only a count. No character strings or raw key codes are exported.
struct P2KeyCounts {
    var attributedDown=0, attributedUp=0, unattributedDown=0, unattributedUp=0
    var superseded=false, overflow=false, posterBound=false
    private var bytes=[UInt8]()

    mutating func saw(down:Bool, trustedKey:CGKeyCode?) {
        if attributedDown+attributedUp+unattributedDown+unattributedUp >= 96 { overflow=true; return }
        if let key=trustedKey {
            if down {
                attributedDown+=1
                if let digit=P2Keypad.codes.firstIndex(of:key), bytes.count<13 { bytes.append(UInt8(digit)+48) }
                else { overflow=true }
            } else { attributedUp+=1 }
        } else if down { unattributedDown+=1 }
        else { unattributedUp+=1 }
    }
    func matchesReceivedPrefix(_ stored:String)->Bool {
        let value=Array(stored.utf8)
        return posterBound && !superseded && !overflow && !value.isEmpty && value.count<=12 &&
            value.count<=bytes.count && Array(bytes.prefix(value.count))==value
    }
    func report(expected:String) -> [String:Any] {
        let h=SHA256.hash(data:Data(bytes)).map{String(format:"%02x",$0)}.joined()
        return ["mode":P2Keypad.transport,"attributedDown":attributedDown,"attributedUp":attributedUp,
                "unattributedDown":unattributedDown,"unattributedUp":unattributedUp,
                "posterBound":posterBound,"sequenceMatches":bytes.count==12 && h==expected,"physicalSuperseded":superseded,"overflow":overflow]
    }
}
