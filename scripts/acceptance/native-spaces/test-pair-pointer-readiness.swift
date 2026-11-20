import Foundation
@main struct ReadinessTests {
    static func main() {
        typealias State = (Int?, String, Bool)
        let nilLS:State=(nil,"registeredProcessUnavailable",true), ok:State=(7,"regularExactBundleAndExecutable",false)
        func replay(_ states:[State], guardReason:String?=nil) -> (Int?,String,Int) {
            var n=0, t=10.0
            let (r,why,_)=pairWaitForRegistration({let v=states[min(n,states.count-1)];n+=1;return v},
                guardScope:{guardReason},clock:{t},wait:{t+=0.05})
            return (r,why,n)
        }
        precondition(replay([ok]) == (7,"ready",1))
        precondition(replay([nilLS,ok,ok]) == (7,"ready",3))
        precondition(replay([nilLS,ok,nilLS,ok,ok]) == (7,"ready",5))
        precondition(replay([nilLS,(nil,"differentRegisteredBundle",false),ok]) == (nil,"differentRegisteredBundle",2))
        precondition(replay([(nil,"registeredPolicyNotRegular",false),ok]).2 == 1)
        precondition(replay([nilLS,ok],guardReason:"userSuperseded") == (nil,"userSuperseded",1))
        precondition(replay([nilLS]).0 == nil && replay([nilLS]).2 <= 16)
        print("PASS: stable LS recovery, explicit mismatch, changed HID and bounded outage")
    }
}
