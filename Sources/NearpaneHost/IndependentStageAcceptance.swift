import AppKit
import NearpaneCore
import NearpaneUI

@MainActor enum IndependentStageAcceptanceHost {
    /// Call before the daily AppDelegate/single-instance/profile paths.
    static func startIfRequested(_ arguments: [String]) -> Bool {
        guard arguments.contains("--independent-stage-acceptance") else { return false }
        guard IndependentStagePolicy.candidateRequested,
              arguments.count == 3, arguments[0] == "--independent-spaces-candidate",
              arguments[1] == "--independent-stage-acceptance",
              Bundle.main.object(forInfoDictionaryKey: "NearpaneIndependentStageAcceptance") as? Int == 1 else { exit(2) }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        Task { @MainActor in
            exit(await NearpaneUI.IndependentStageAcceptance.run(configuration: URL(fileURLWithPath: arguments[2])))
        }
        application.run()
        return true
    }
}
