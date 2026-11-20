import Foundation
import CryptoKit

enum TranslationProof {
    static func digest(_ text:String) -> String {
        SHA256.hash(data:Data(text.utf8)).map { String(format:"%02x",$0) }.joined()
    }
    static func panel(_ id:UUID, pid:Int32, window:UInt32, text:String) -> String {
        digest("panel-v1|\(id.uuidString)|\(pid)|\(window)|\(digest(text))")
    }
    /// Each stage must occur after the previous one for this same request. A loading
    /// panel cannot satisfy the final panel's digest. Earlier duplicate reads are harmless.
    static func follows(_ records:[[String:String]], _ required:[(String,String)]) -> Bool {
        var position=0, last = -Double.infinity
        for row in records {
            guard let spelling=row["uptime"], let time=Double(spelling), time.isFinite, time >= last else { return false }
            last=time
            if position<required.count, row["stage"]==required[position].0 && row["sha256"]==required[position].1 { position+=1 }
        }
        return !required.isEmpty && position==required.count
    }
    static func translated(_ records:[[String:String]],source:String,answer:String,id:UUID,pid:Int32,window:UInt32)->Bool {
        let text=digest(source), final=digest(answer)
        return follows(records,[("serviceCallback",text),("requestQueued",text),("hostReceived",text),
                               ("modelInstalled","-"),("translated",final),("wordCommitted",final),("panelVisible",panel(id,pid:pid,window:window,text:answer))])
    }
}
