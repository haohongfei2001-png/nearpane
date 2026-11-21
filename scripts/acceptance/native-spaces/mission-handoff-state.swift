import Foundation

enum HandoffPhase: String { case before, presented, after }

func handoffMetric(_ fields: [String: Any], pid: Int32, phase: HandoffPhase) -> Bool {
    let exposed = phase == .presented
    func exact(_ name: String, _ expected: Int) -> Bool { (fields[name] as? NSNumber)?.intValue == expected }
    return exact("pid", Int(pid)) && exact("stageManagerOwnsDispatch", 0) &&
        exact("missionControlPresented", exposed ? 1 : 0) && exact("windowDispatchEligible", exposed ? 0 : 1) &&
        exact("overviewShortcutRegistered", exposed ? 0 : 1) && exact("activeStreams", 0) &&
        exact("capturesInFlight", 0) && (fields["deliveredFrames"] as? Int).map { $0 >= 0 } == true &&
        (fields["captureRequests"] as? Int).map { $0 >= 0 } == true &&
        (!exposed || (exact("visibleDisplays", 0) && exact("gallerySessions", 0)))
}

func handoffQuiescent(_ first: [String: Any], _ second: [String: Any]) -> Bool {
    ["deliveredFrames", "captureRequests"].allSatisfy {
        guard let a = first[$0] as? Int, let b = second[$0] as? Int else { return false }
        return a >= 0 && a == b
    }
}
