import Foundation

// A bounded read-only recovery before a first pointer event. An explicit identity
// or policy mismatch cannot become another read or an input request.
func pairWaitForRegistration<T>(_ read: () -> (T?, String, Bool), guardScope: () -> String?,
                                clock: () -> Double, wait: () -> Void) -> (T?, String, [String:Any]) {
    let begin = clock(), deadline = begin+0.65
    var reads = [[String:Any]](), firstMissing: String?, consecutive = 0
    func done(_ app:T?,_ why:String) -> (T?,String,[String:Any]) {
        (app,why,["reason":why,"reads":reads,"firstRefusal":firstMissing as Any? ?? NSNull(),
                  "started":begin,"ended":clock(),"issued":false] as [String:Any])
    }
    repeat {
        let reading = read(), now = clock()
        reads.append(["at":now,"state":reading.1] as [String:Any])
        if let current = reading.0 {
            consecutive += 1
            if firstMissing == nil || consecutive >= 2 {
                if firstMissing != nil, let why=guardScope() {return done(nil,why)}
                return done(current,"ready")
            }
        } else {
            consecutive=0
            if firstMissing == nil {firstMissing=reading.1}
            if !reading.2 {return done(nil,reading.1)}
        }
        if let why=guardScope() {return done(nil,why)}
        wait()
    } while clock() < deadline && reads.count < 16
    return done(nil,"registeredAppReadinessDidNotStabilize")
}
