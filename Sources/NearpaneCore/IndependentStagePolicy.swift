import Foundation

/// One product route. Historical Corner and Apple-strip code is retained only for evidence
/// and recovery of old sessions; neither is a fallback for the replacement engine.
public enum IndependentStagePolicy {
    public static let backend = StageWindowBackend.spaces
    public static let mirrorsAppleStrip = false
    public static let allowsCornerFallback = false
    public static let candidateBundleID = "com.holdsnow.nearpane.independent-stage-candidate"

    /// An isolated, explicitly launched candidate exercises the production R4 path without
    /// claiming a release qualification or taking over the installed daily application's identity.
    public static var candidateRequested: Bool {
        Bundle.main.bundleIdentifier == candidateBundleID &&
        ProcessInfo.processInfo.arguments.contains("--independent-spaces-candidate")
    }

    public static var candidatePIDs: Set<Int32> {
        Set((ProcessInfo.processInfo.environment["NEARPANE_SPACES_CANDIDATE_PIDS"] ?? "")
            .split(separator: ",").compactMap { Int32($0) }.filter { $0 > 1 })
    }
}
