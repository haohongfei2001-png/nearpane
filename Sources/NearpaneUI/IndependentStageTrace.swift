import Foundation

/// Opt-in diagnostics for the real product path. These observations never grant
/// dispatch permission, synthesize an input, or replace a physical result.
@MainActor enum IndependentStageTrace {
    static func record(_ phase: String, _ fields: [String: Any] = [:]) {
        guard ProcessInfo.processInfo.environment["NP_SPACES_LAUNCH_TRACE"] != nil else { return }
        var event = fields
        event["event"] = "independentStageProduct"
        event["phase"] = phase
        event["uptime"] = ProcessInfo.processInfo.systemUptime
        guard var data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) else { return }
        data.append(0x0a)
        try? FileHandle.standardError.write(contentsOf: data)
    }
}
