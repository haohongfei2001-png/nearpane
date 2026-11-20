import Foundation
import CoreGraphics

@main
struct PairPointerVisualChecks {
    static func main() throws {
        var passed = [String]()
        func check(_ test: String, _ predicate: @autoclosure () -> Bool) {
            guard predicate() else { fatalError(test) }
            passed.append(test)
        }
        let display = CGRect(x:0,y:0,width:1470,height:956)
        let a = CGRect(x:555,y:392,width:320,height:193), b = CGRect(x:585,y:367,width:320,height:193)
        guard let crop = PairVisualEvidence.crop(frames:[a,b],display:display) else { fatalError("recorded fixture crop") }
        check("recordedFixtureFramesHaveInteriorOverlap", a.contains(crop) && b.contains(crop) && crop.size == CGSize(width:8,height:8))
        check("noOverlapDoesNotRead", PairVisualEvidence.crop(frames:[a,b.offsetBy(dx:400,dy:0)],display:display) == nil)
        check("titlebarOnlyDoesNotRead", PairVisualEvidence.crop(frames:[a,a.offsetBy(dx:0,dy:179)],display:display) == nil)

        func row(_ n:UInt32,_ pid:pid_t,_ frame:CGRect,_ alpha:Double = 1,_ layer:Int = 0)->[String:Any] {
            [kCGWindowNumber as String:n,kCGWindowOwnerPID as String:pid,kCGWindowLayer as String:layer,
             kCGWindowIsOnscreen as String:true,kCGWindowAlpha as String:alpha,kCGWindowBounds as String:frame.dictionaryRepresentation]
        }
        let first=row(21,42,a), second=row(22,42,b)
        func top(_ rows:[[String:Any]])->Int? {
            try? PairVisualEvidence.physicalTop(rows:rows,frames:[a,b],numbers:[21,22],pid:42,crop:crop)
        }
        check("frontA", top([first,second]) == 0)
        check("frontB", top([second,first]) == 1)
        check("foreignOverlayStops", top([row(9,77,crop,0.2,12),first,second]) == nil)
        check("unknownOwnerStops", top([[kCGWindowBounds as String:crop.dictionaryRepresentation],first,second]) == nil)
        check("newGenerationSharingNumberStops", top([row(21,91,a),second]) == nil)
        check("translucentFixtureStops", top([row(21,42,a,0.7),second]) == nil)
        check("changedSiblingGeometryStops", top([first,row(22,42,b.offsetBy(dx:1,dy:0))]) == nil)
        check("missingSiblingStops", top([first]) == nil)
        check("duplicateWindowStops", top([first,first,second]) == nil)

        func patch(_ bgra:[UInt8])->[UInt8] { Array(repeating:bgra,count:64).flatMap{$0} }
        func slot(_ bytes:[UInt8])->Int? { bytes.withUnsafeBufferPointer { PairPointerPalette.slot(bgra:$0.baseAddress!,stride:32,side:8) } }
        let blue=patch([204,123,45,255]), orange=patch([53,139,227,255])
        check("all64A", slot(blue) == 0);check("all64B", slot(orange) == 1)
        var bad=blue;bad[255]=254
        check("oneTranslucentPixel", slot(bad) == nil)
        bad=orange;bad[85]=160
        check("oneOffPalettePixel", slot(bad) == nil)
        check("blankIsNotTarget", slot(patch([0,0,0,255])) == nil)
        func sample(_ s:Int,_ a:Double,_ b:Double)->PairPhysicalSample { .init(from:a,to:b,slot:s) }
        let source=sample(0,1,1.003), destination=sample(1,1.020,1.024)
        func eligible(_ s:Int,_ b:PairPhysicalSample,_ a:PairPhysicalSample)->Bool {
            PairVisualEvidence.eligible(slot:s,target:1,presentation:1.014,uncertainty:0.0002,before:b,after:a)
        }
        check("authenticatedForwardHandoff", eligible(1,source,destination))
        check("stableTargetRequiresTargetPixels", !eligible(0,sample(1,1,1.002),destination))
        check("reverseHandoffRefused", !eligible(0,sample(1,1,1.002),sample(0,1.020,1.024)))
        check("noBracketingReadRefused", !eligible(1,source,sample(1,1.010,1.012)))
        check("lateObserverRefused", !eligible(1,source,sample(1,1.070,1.074)))
        func frame(_ s:Int,_ t:Double,_ n:UInt64)->PairVisualFrame {
            .init(slot:s,ticks:n,time:t,callback:t+0.001,before:sample(s,t-0.010,t-0.006),after:sample(s,t+0.005,t+0.009))
        }
        let old=frame(0,1.0,1),holding=frame(0,1.052,2),new=frame(1,1.08,3)
        func receipt(_ samples:[PairVisualFrame])->[String:Any] {
            PairVisualEvidence.receipt(frames:samples,target:1,uncertainty:0.0002,down:1.03...1.031,up:1.065...1.066)
        }
        let r=receipt([old,holding,new])
        let d=r["downToVisibleMS"] as? [String:Double], u=r["upToVisibleMS"] as? [String:Double]
        check("independentDisplayRange", r["status"] as? String == "OBSERVED" && abs((d?["lower"] ?? 999) - 20.8) < 0.0001 && abs((d?["upper"] ?? 999) - 59) < 0.0001)
        check("doesNotClampPossiblePreMouseUpPresentation", abs((u?["lower"] ?? 999) + 14.2) < 0.0001)
        check("noTargetNotAXSuccess", receipt([old,holding])["status"] as? String == "UNKNOWN")
        check("targetBeforeClickUnknown", receipt([old,frame(1,1.018,2)])["status"] as? String == "UNKNOWN")
        check("noSourceBaselineUnknown", receipt([new])["status"] as? String == "UNKNOWN")
        check("lateYankUnknown", receipt([old,new,frame(0,1.092,4)])["status"] as? String == "UNKNOWN")
        check("duplicatePresentationNotNewTarget", receipt([old,frame(1,1.08,1)])["status"] as? String == "UNKNOWN")
        check("earlyFrameClockMustAgree", PreviewClock.presentationBounds(display:1.005,pts:1.050,callback:1.001) == nil)
        check("earlyFrameWithMatchedClocksBounded", PreviewClock.presentationBounds(display:1.005,pts:1.005,callback:1.001) != nil)
        let data=try JSONSerialization.data(withJSONObject:["status":"PASS","mode":"offline","checks":passed],options:[.sortedKeys])
        print(String(decoding:data,as:UTF8.self))
    }
}
