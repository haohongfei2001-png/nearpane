import AppKit

@main struct FirstDocumentPresentation {
    static func main() {
        let s=UUID().uuidString, hid=[UInt32](repeating:2,count:13)
        let admitted=P2LaunchPresentation(session:s,originalFront:33,hardware:hid,admittedAt:114)
        func may(_ time:Double=115,_ hardware:[UInt32]=hid,_ front:pid_t?=33,_ down:Bool=false,_ session:String=s)->Bool {
            admitted.allows(now:time,hid:hardware,front:front,fixture:44,mouseDown:down,session:session)
        }
        precondition(may() && may(116,hid,44))
        precondition(!may(124) && !may(111) && !may(116,hid,55) && !may(116,hid,nil))
        precondition(!may(116,hid,44,true) && !may(116,[UInt32](repeating:3,count:13)) && !may(116,hid,44,false,UUID().uuidString))
    }
}
