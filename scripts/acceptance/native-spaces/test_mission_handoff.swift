import Foundation

@main enum HandoffChecks {
    static func main() {
        let base: [String: Any] = ["pid":45, "stageManagerOwnsDispatch":0, "missionControlPresented":0, "windowDispatchEligible":1,
                                   "overviewShortcutRegistered":1, "activeStreams":0, "capturesInFlight":0, "deliveredFrames":20,
                                   "captureRequests":2, "visibleDisplays":1, "gallerySessions":0]
        precondition(handoffMetric(base, pid:45, phase:.before) && handoffMetric(base, pid:45, phase:.after))
        var open = base
        for (key,value) in ["missionControlPresented":1,"windowDispatchEligible":0,"overviewShortcutRegistered":0,"visibleDisplays":0] { open[key] = value }
        precondition(handoffMetric(open, pid:45, phase:.presented))
        for key in ["pid","stageManagerOwnsDispatch","missionControlPresented","windowDispatchEligible","overviewShortcutRegistered",
                    "activeStreams","capturesInFlight","visibleDisplays","gallerySessions","deliveredFrames","captureRequests"] {
            var missing=open; missing.removeValue(forKey:key); precondition(!handoffMetric(missing,pid:45,phase:.presented))
        }
        for key in ["stageManagerOwnsDispatch","windowDispatchEligible","overviewShortcutRegistered","activeStreams","capturesInFlight","visibleDisplays","gallerySessions"] {
            var active=open; active[key]=1; precondition(!handoffMetric(active,pid:45,phase:.presented))
        }
        precondition(handoffQuiescent(open,open))
        var frames=open; frames["deliveredFrames"]=21; precondition(!handoffQuiescent(open,frames))
        var requests=open; requests["captureRequests"]=3; precondition(!handoffQuiescent(open,requests))
        precondition(!handoffMetric(open,pid:46,phase:.presented))
        print("25 scope, ownership, hotkey and stream checks passed")
    }
}
