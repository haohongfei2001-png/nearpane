import Foundation

// Offline policy checks; this executable never requests display data, AX or a window list.
@main struct CheckPreviewScope {
    static func main() {
        guard CommandLine.arguments.count==2 else {exit(2)}
        let raw=CommandLine.arguments[1]
        guard let kit=PreviewCensus.ownedTemporaryURL(raw),kit.path==raw,
              PreviewCensus.ownedTemporaryURL(String(raw.dropFirst("/private".count)))?.path==raw,
              PreviewCensus.ownedTemporaryURL(raw+"/../"+kit.lastPathComponent)==nil,
              PreviewCensus.ownedTemporaryURL("/tmp")==nil else {exit(3)}
        let samples:[(Bool,Bool,Bool,Bool,Bool,Bool,Bool,String)]=[
            (false,false,true,false,true,true,true,"unverifiedThinOffscreen"),
            (false,false,true,false,true,true,false,"unverifiedOrdinary"),
            (true,false,true,false,false,false,false,"signedCompositor"),
            (true,false,false,false,false,false,false,"unverifiedOrdinary"),
            (false,true,true,false,false,false,false,"unverifiedOrdinary"),
            (false,true,true,false,true,false,false,"unverifiedOrdinary"),
            (false,true,true,false,true,true,false,"enrolledNonDocument"),
            (false,true,true,true,false,false,false,"enrolledNonDocument")]
        for row in samples {
            guard PreviewCensus.disposition(signedCompositor:row.0,fixture:row.1,validShape:row.2,explicitlyNonstandard:row.3,
                                             absentFromFixtureAX:row.4,unpresented:row.5,thinOffscreen:row.6)==row.7 else{exit(4)}
        }
        // The v4 shape was a drawn, single-Space nonstandard child from the signed fixture.
        // Only our own command-line PID is used; no GUI or desktop is inspected.
        func recognized(owner:pid_t=getpid(),oneSpace:Bool=true,role:String?="AXWindow",subrole:String?="AXFloatingWindow",
                        count:Int?=1,bounds:CGRect=CGRect(x:12,y:14,width:40,height:30),on:Bool=true)->Bool {
            PreviewCensus.extra(pid:getpid(),fixture:owner,rect:bounds,on:on,drawn:on,singleSpace:oneSpace,publicNow:on,publicAll:on,
                                axCount:count,role:role,subrole:subrole,strict:true).admitted
        }
        guard recognized(),!recognized(owner:0),!recognized(oneSpace:false),!recognized(role:nil),
              !recognized(subrole:"AXStandardWindow"),!recognized(subrole:nil),!recognized(count:2),
              !recognized(role:nil,subrole:nil,count:0,on:false),!recognized(bounds:.zero) else{exit(5)}
        print("4 private path, 8 scoped disposition and 9 strict Split View auxiliary checks passed")
    }
}
