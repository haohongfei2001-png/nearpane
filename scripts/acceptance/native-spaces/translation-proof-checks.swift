import Foundation

@main enum TranslationProofChecks {
    static func main() {
        let id=UUID(), pid:Int32=123, window:UInt32=45, input="Synthetic", answer="合成"
        let hash=TranslationProof.digest(input), result=TranslationProof.digest(answer)
        let bound=TranslationProof.panel(id,pid:pid,window:window,text:answer)
        let order=[("serviceCallback",hash),("requestQueued",hash),("hostReceived",hash),("modelInstalled","-"),
                   ("translated",result),("wordCommitted",result),("panelVisible",bound)]
        let rows=order.enumerated().map { ["stage":$0.element.0,"sha256":$0.element.1,"uptime":String($0.offset+1)] }
        func qualifies(_ records:[[String:String]],_ owner:Int32=pid,_ number:UInt32=window)->Bool {
            TranslationProof.translated(records,source:input,answer:answer,id:id,pid:owner,window:number)
        }
        precondition(qualifies(rows))
        precondition(!qualifies(rows,pid+1) && !qualifies(rows,pid,window+1))
        var bad=rows;bad[6]["sha256"]=TranslationProof.panel(id,pid:pid,window:window,text:"正在查询…");precondition(!qualifies(bad))
        bad=rows;bad.swapAt(3,4);precondition(!qualifies(bad))
        bad=rows;bad[2]["sha256"]=result;precondition(!qualifies(bad))
        precondition(!qualifies(Array(rows.dropFirst())))
        precondition(TranslationProof.follows([["stage":"wordReopened","sha256":result,"uptime":"19"]],[("wordReopened",result)]))
        print("8 ordered and identity-bound Services proof checks passed")
    }
}
