import AppKit

@main struct PreparationAdmissionTests {
    static func main() throws {
        let session=UUID().uuidString
        let counters=[UInt32](repeating:1,count:13)
        let request=P2InitialActivation(session:session,intent:UUID().uuidString,readerHash:String(repeating:"1",count:40),
            pid:70,reader:73,allowedFront:61,birth:100,readerBirth:192,numbers:[111,112],hid:counters,expires:220)
        func admitted(_ pid:pid_t=70, _ birth:UInt64=100, _ front:pid_t?=61, _ nums:[UInt32]=[111,112],
                      _ hid:[UInt32]=counters,_ now:Double=219,_ trial:Bool=false)->Bool {
            request.admits(fixture:pid,generation:birth,current:nums,hardware:hid,front:front,
                           privateSession:session,now:now,formalIntentExists:trial)
        }
        precondition(admitted() && admitted(70,100,70))
        precondition(!admitted(70,101) && !admitted(71) && !admitted(70,100,83))
        precondition(!admitted(70,100,nil) && !admitted(70,100,61,[111,113]))
        precondition(!admitted(70,100,61,[111,112],counters,221) && !admitted(70,100,61,[111,112],counters,219,true))
        precondition(!admitted(70,100,61,[111,112],[UInt32](repeating:2,count:13)))
    }
}
