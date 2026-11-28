// Offline checks share the signed reader's predicates and use no window, display, AX or input API.
import Foundation

@main
struct P2StageFixtureChecks {
    static func main() {
        let screen = CGRect(x:0, y:0, width:1512, height:982)
        let enrolled = [1355.0, 446, 99, 97]
        let rect = CGRect(x:1355, y:446, width:99, height:97)
        precondition(p2StageBoundsMatch(rect, on:screen, enrolled:enrolled))
        precondition(!p2StageBoundsMatch(rect.offsetBy(dx:0.25, dy:0), on:screen, enrolled:enrolled))
        precondition(!p2StageBoundsMatch(CGRect(x:200,y:446,width:99,height:97), on:screen, enrolled:[200,446,99,97]))
        precondition(!p2StageBoundsMatch(CGRect(x:1355,y:446,width:99,height:250), on:screen, enrolled:[1355,446,99,250]))
        precondition(p2StageHidden(metadata:nil, cg:false, appKit:false, ax:false))
        precondition(p2StageHidden(metadata:false, cg:false, appKit:false, ax:false))
        for (metadata,cg,appKit,ax) in [(true as Any?,false,false,false),
                                         (nil,true,false,false),(nil,false,true,false),(nil,false,false,true),
                                         ("invalid" as Any?,false,false,false)] {
            precondition(!p2StageHidden(metadata:metadata, cg:cg, appKit:appKit, ax:ax))
        }
        print("PASS 11 native geometry and visibility assertions")
    }
}
