import AppKit

/// Send a single logical marker as ordinary, PID-addressed numeric keypad events.
/// Hold the same process and private CGEventSource until the scoped AppKit receiver
/// acknowledges each make/break pair. A missing reply never causes another post.
func p2PostDocumentKeys(_ text:String, source:CGEventSource, input:[String:Any], fixture:pid_t,
                        birth:UInt64, path:URL, session:String, intent:String, tag:Int64, target:UInt32,
                        gate:()->Object?) -> Object {
    guard let keys=P2Keypad.keys(text),let digest=input["markerDigest"] as? String,birthMicroseconds(fixture)==birth else {
        return ["issued":false,"reason":"unadmittedOrdinaryMarker"]
    }
    let start=ProcessInfo.processInfo.systemUptime
    var down=0,up=0,last:[String:Any]=[:]
    var before:Double?,after:Double?,firstAck:Double?
    func result(_ reason:String)->Object {
        var r=input
        r["issued"]=down>0;r["complete"]=down==keys.count && up==keys.count && reason=="acknowledged"
        r["reason"]=reason;r["transport"]=P2Keypad.transport;r["postedDown"]=down;r["postedUp"]=up
        r["senderPID"]=getpid();r["senderBirth"]=birthMicroseconds(getpid()) as Any? ?? NSNull()
        r["beforePost"]=before as Any? ?? NSNull();r["afterPost"]=after as Any? ?? NSNull()
        r["firstReceiverAck"]=firstAck as Any? ?? NSNull();r["senderAliveUntil"]=ProcessInfo.processInfo.systemUptime
        r["receiver"]=last
        return r
    }
    func receipt()->[String:Any]? {
        let fd=open(path.appendingPathComponent("marker-watch-response.json").path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
        guard fd>=0 else{return nil}
        let f=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        var st=stat()
        guard fstat(fd,&st)==0,st.st_uid==getuid(),st.st_nlink==1,st.st_mode&S_IFMT==S_IFREG,st.st_mode&0o077==0,
              st.st_size>0,st.st_size<65536,let data=try? f.read(upToCount:65536),Int64(data.count)==st.st_size,
              let raw=try? JSONSerialization.jsonObject(with:data) as? Object,raw["session"] as? String==session,
              raw["intent"] as? String==intent,raw["digest"] as? String==digest,raw["pid"] as? Int32==fixture,
              raw["birth"] as? UInt64==birth,raw["target"] as? UInt32==target,raw["status"] as? String=="ARMED",
              let counters=raw["keyDelivery"] as? Object,counters["mode"] as? String==P2Keypad.transport else{return nil}
        return counters
    }
    func waitUntil(_ seconds:Double) {
        Thread.sleep(forTimeInterval:seconds)
    }
    return withExtendedLifetime(source) {
        let enrollmentDeadline=start+1
        repeat {
            if let seen=receipt(),seen["posterBound"] as? Bool==true {
                last=seen; break
            }
            waitUntil(0.012)
        } while ProcessInfo.processInfo.systemUptime < enrollmentDeadline
        guard last["posterBound"] as? Bool==true else{return result("liveSenderNotAcknowledgedByReceiver")}
        for key in keys {
            guard let pair=P2Keypad.pair(key,source:source,tag:tag) else{return result("keyCreationFailed")}
            if let refusal=gate() {return result(refusal["reason"] as? String ?? "scopeChanged")}
            if before==nil {before=ProcessInfo.processInfo.systemUptime}
            pair.0.postToPid(fixture);down+=1;after=ProcessInfo.processInfo.systemUptime
            waitUntil(0.018)
            if let refusal=gate() {return result(refusal["reason"] as? String ?? "scopeChanged")}
            pair.1.postToPid(fixture);up+=1;after=ProcessInfo.processInfo.systemUptime
            let deadline=min(start+8,ProcessInfo.processInfo.systemUptime+0.65)
            var acknowledged=false
            repeat {
                if let seen=receipt() {
                    last=seen
                    if seen["physicalSuperseded"] as? Bool==true {return result("userSuperseded")}
                    if seen["overflow"] as? Bool==true {return result("receiverOverflow")}
                    if seen["attributedDown"] as? Int==down,seen["attributedUp"] as? Int==up {
                        firstAck=firstAck ?? ProcessInfo.processInfo.systemUptime;acknowledged=true;break
                    }
                }
                waitUntil(0.012)
            } while ProcessInfo.processInfo.systemUptime<deadline
            guard acknowledged else{return result("receiverPairUnconfirmed")}
        }
        return result(last["sequenceMatches"] as? Bool==true ? "acknowledged":"receivedSequenceUnconfirmed")
    }
}
