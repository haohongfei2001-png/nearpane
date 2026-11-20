// Run as a CLI with manufactured dictionaries. No window enumeration, screenshot, AX query, or application launch.
import Foundation
import CoreGraphics

@main struct PanelObserverChecks {
    static func main() {
        let id=UUID(),pid:Int32=71,win:UInt32=320,phrase="The blue bicycle",answer="请先在 macOS 翻译设置中下载所需语言。"
        let src=TranslationProof.digest(phrase),final=TranslationProof.panel(id,pid:pid,window:win,text:answer)
        let loading=TranslationProof.panel(id,pid:pid,window:win,text:"正在查询…")
        let sequence=[("serviceCallback",src),("requestQueued",src),("hostReceived",src),("anchorPointer","-"),
                      ("panelVisible",loading),("modelMissing","-"),("anchorPointer","-"),("panelVisible",final)]
        let records=sequence.enumerated().map{["stage":$0.element.0,"sha256":$0.element.1,"uptime":String($0.offset+1)]}
        var checks=0
        func verify(_ condition:Bool) {precondition(condition);checks+=1}
        func bound(_ rows:[[String:String]],_ start:Double=8.1,_ end:Double=8.2,_ owner:Int32=pid,
                   _ number:UInt32=win,_ text:String=answer) -> String? {
            TranslationProof.presentation(rows,source:phrase,answer:text,terminal:"modelMissing",id:id,
                                          pid:owner,window:number,begin:start,end:end)
        }
        let generic=records.map { row in
            var row=row
            if row["stage"]=="anchorPointer" {row["stage"]="anchorFeedbackPointer"}
            return row
        }
        verify(bound(generic)=="anchorFeedbackPointer")
        verify(!TranslationProof.sourceAnchor(bound(generic)))
        verify(TranslationProof.sourceAnchor("anchorPointer") && TranslationProof.sourceAnchor("anchorSelection"))
        verify(!TranslationProof.sourceAnchor(nil))
        let visible=CGRect(x:0,y:30,width:1200,height:840),pointer=CGPoint(x:1195,y:4)
        verify(TranslationProof.clampedPointerMatch(CGRect(x:920,y:30,width:280,height:40),point:pointer,visible:visible))
        verify(!TranslationProof.clampedPointerMatch(CGRect(x:850,y:30,width:280,height:40),point:pointer,visible:visible))
        verify(TranslationProof.clampedPointerMatch(CGRect(x:100,y:105,width:280,height:40),point:CGPoint(x:100,y:100),visible:visible))
        verify(bound(records)=="anchorPointer");verify(bound(records,5.3,5.4)==nil)
        verify(bound(records,7.8,8.1)==nil);verify(bound(records,8.1,8.2,pid+1)==nil)
        verify(bound(records,8.1,8.2,pid,win+1)==nil);verify(bound(records,8.1,8.2,pid,win,"下载")==nil)
        var changed=records
        changed.append(["stage":"panelUnavailable","sha256":"-","uptime":"8.15"])
        verify(bound(changed)==nil);verify(bound(changed,8.01,8.07)=="anchorPointer")
        changed=records;changed[0]["sha256"]=TranslationProof.digest("another phrase");verify(bound(changed)==nil)
        changed=records;changed.remove(at:5);verify(bound(changed)==nil)
        changed=records;changed.swapAt(1,2);verify(bound(changed)==nil)
        let bounds=CGRect(x:100,y:120,width:276,height:37),layer=101
        func row(_ n:UInt32,_ r:CGRect,_ owner:Int32,_ z:Int,_ alpha:Double?) -> [String:Any] {
            var fields:[String:Any]=[kCGWindowNumber as String:n,kCGWindowBounds as String:r.dictionaryRepresentation,
                kCGWindowOwnerPID as String:owner,kCGWindowLayer as String:z]
            if let alpha {fields[kCGWindowAlpha as String]=alpha}
            return fields
        }
        let target=row(win,bounds,pid,layer,1), cover=row(430,bounds,92,120,1), transparent=row(430,bounds,92,120,0)
        func stack(_ rows:[[String:Any]]?)->TranslationStackWitness {translationStackRows(rows,pid,93,win,bounds,level:layer)}
        verify(stack([target]).clear);verify(stack([cover,target]).reason=="occludedByHigherWindow")
        verify(stack([cover,target]).blockingOwner=="other");verify(stack([target,cover]).clear)
        verify(stack([transparent,target]).clear);verify(stack(nil).reason=="stackUnavailable")
        verify(stack([row(430,bounds,92,120,nil),target]).reason=="overlappingWindowOpacityUnavailable")
        verify(stack([row(430,CGRect(x:900,y:800,width:10,height:10),92,120,nil),target]).clear)
        verify(stack([row(win,bounds.offsetBy(dx:2,dy:0),pid,layer,1)]).reason=="targetIdentityGeometryOrOpacityChanged")
        verify(stack([row(win,bounds,pid,layer,0)]).clear==false);verify(stack([]).reason=="targetMissing")
        for refused in 0..<7 {
            let flags=(0..<7).map{$0 != refused}
            let sample=TranslationPanelVerdict(isBound:flags[0],panelCurrent:flags[1],sourceFocused:flags[2],
                anchorMatches:flags[3],hostSameGeneration:flags[4],imageCaptured:flags[5],contentMatches:flags[6])
            verify(!sample.passed && sample.fields.values.filter{!$0}.count==1)
        }
        verify(TranslationPanelVerdict(isBound:true,panelCurrent:true,sourceFocused:true,anchorMatches:true,
                                      hostSameGeneration:true,imageCaptured:true,contentMatches:true).passed)
        for (attempted,returned,retained,expected) in [
            (false,false,false,"withheldBeforeCapture"),(false,false,true,"withheldBeforeCapture"),
            (true,false,false,"ownedWindowCaptureUnavailable"),(true,true,false,"withheldAfterCapture"),
            (true,true,true,"capturedInMemory")] {
            verify(TranslationProof.captureState(attempted:attempted,returned:returned,retained:retained)==expected)
        }
        let fixed=TranslationProof.digest(TranslationProof.normalized(answer))
        verify(TranslationProof.stockNotice(in:[id:[fixed]])?.request==id)
        verify(TranslationProof.stockNotice(in:[id:[fixed,TranslationProof.digest("")]])?.contentHash==fixed)
        verify(TranslationProof.stockNotice(in:[id:[fixed,TranslationProof.digest("other")]])==nil)
        verify(TranslationProof.stockNotice(in:[id:[fixed],UUID():[fixed]])==nil)
        verify(TranslationProof.stockNotice(in:[:])==nil)
        if CommandLine.arguments.count==2 {
            let url=URL(fileURLWithPath:CommandLine.arguments[1])
            let record=try! JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any]
            let samples=record["panelSamples"] as! [[String:Any]]
            verify(record["status"] as? String=="UNKNOWN" && samples.count==6)
            for sample in samples {
                let start=sample["sourceBefore"] as! [String:Bool],end=sample["sourceAfter"] as! [String:Bool]
                verify(start["originalFixture"]==true && end["originalFixture"]==true && start["workspaceFront"]==false && end["workspaceFront"]==false)
                let checks=sample["checks"] as! [String:Bool]
                verify(checks["isBound"]==true && checks["panelCurrent"]==true && checks["sourceFocused"]==false)
                let originalAttempted=sample["sameHostGeneration"] as? Bool==true && (sample["stackBefore"] as? [String:String])?["status"]=="clear" && start.values.allSatisfy{$0}
                verify(!originalAttempted && TranslationProof.captureState(attempted:originalAttempted,returned:false,retained:false)=="withheldBeforeCapture")
            }
        }
        print("\(checks) single-sample identity, chronology, contents, source and occlusion checks passed")
    }
}
