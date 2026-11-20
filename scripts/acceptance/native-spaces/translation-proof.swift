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

extension TranslationProof {
    // The image interval must lie inside a single final presentation of this request.
    // A delayed log query may contain a later presentation as well.
    static func presentation(_ records:[[String:String]], source:String, answer:String, terminal:String,
                             id:UUID, pid:Int32, window:UInt32, begin:Double, end:Double) -> String? {
        guard !answer.isEmpty, begin.isFinite, end >= begin else { return nil }
        let expected = panel(id,pid:pid,window:window,text:answer), input = digest(source)
        let terminalHash = terminal == "wordCommitted" ? digest(answer) : "-"
        let prefix = records.filter { (Double($0["uptime"] ?? "") ?? .infinity) <= begin }
        guard follows(records,[("serviceCallback",input),("requestQueued",input),("hostReceived",input)]),
              let visible = prefix.lastIndex(where:{ ["panelVisible","panelUnavailable"].contains($0["stage"] ?? "") }),
              prefix[visible]["stage"] == "panelVisible", prefix[visible]["sha256"] == expected,
              let anchor = prefix[..<visible].last(where:{["anchorSelection","anchorPointer"].contains($0["stage"] ?? "")})?["stage"],
              follows(Array(prefix[...visible]),[("serviceCallback",input),("requestQueued",input),("hostReceived",input),
                    (terminal,terminalHash),(anchor,"-"),("panelVisible",expected)]) else { return nil }
        let changed = records.contains { row in
            guard let time=Double(row["uptime"] ?? ""), time > begin && time <= end else { return false }
            return ["panelVisible","panelUnavailable","anchorPointer","anchorSelection"].contains(row["stage"] ?? "")
        }
        return changed ? nil : anchor
    }

    static func normalized(_ text:String) -> String { text.filter { $0.isLetter || $0.isNumber }.lowercased() }
}

struct TranslationPanelVerdict {
    let isBound, panelCurrent, sourceFocused, anchorMatches, hostSameGeneration, imageCaptured, contentMatches: Bool
    var passed:Bool { isBound && panelCurrent && sourceFocused && anchorMatches && hostSameGeneration && imageCaptured && contentMatches }
    var fields:[String:Bool] {
        ["isBound":isBound,"panelCurrent":panelCurrent,"sourceFocused":sourceFocused,"anchorMatches":anchorMatches,
         "hostSameGeneration":hostSameGeneration,"imageCaptured":imageCaptured,"contentMatches":contentMatches]
    }
}
