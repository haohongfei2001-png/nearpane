import Foundation
import OSLog

/// Correlate a sidebar click with its first AX write and its exact focus witness.
/// The operation UUID is unrelated to the window, application, display or document.
package struct WindowFocusTiming: Sendable {
    private static let log = Logger(subsystem: "com.holdsnow.nearpane.alpha", category: "WindowFocusLatency")
    package enum Path: String { case host, worker, application }
    package enum Write: String { case main, frontmost, raise, focusedWindow, unminimize }
    package let id: UUID

    package init(id: UUID) { self.id = id }

    package static func begin() -> Self {
        let item = Self(id: UUID())
        item.record("click")
        return item
    }

    private func record(_ phase: String, _ route: String = "sidebar", _ action: String = "none") {
        Self.log.info("operation=\(id.uuidString, privacy: .public) phase=\(phase, privacy: .public) route=\(route, privacy: .public) action=\(action, privacy: .public) uptime=\(ProcessInfo.processInfo.systemUptime, format: .fixed(precision: 6), privacy: .public)")
    }

    package func scopeFindings(_ findings: [OrdinaryFocusScopeFinding], from source: Path) {
        for item in findings {
            Self.log.info("operation=\(id.uuidString, privacy: .public) phase=targetScopeFact route=\(source.rawValue, privacy: .public) action=\(item.reason.rawValue, privacy: .public) uptime=\(ProcessInfo.processInfo.systemUptime, format: .fixed(precision: 6), privacy: .public) point=\(item.point.rawValue, privacy: .public) evidence=\(item.state.rawValue, privacy: .public) expected=\(item.expected ?? -1, privacy: .public) observed=\(item.observed ?? -1, privacy: .public)")
        }
    }

    package func confirmed(_ path: Path) { record("exactFocus", path.rawValue) }
    package func completed(_ path: Path) { record("returned", path.rawValue) }
    package func beforeApplicationActivation() { record("beforeApplicationActivation", Path.application.rawValue) }

    package struct Writes {
        private var timing: WindowFocusTiming?
        private let path: Path
        package init(_ timing: WindowFocusTiming?, _ path: Path) { self.timing = timing; self.path = path }
        package mutating func before(_ action: Write) {
            timing?.record("beforeAX", path.rawValue, action.rawValue)
            timing = nil
        }
    }
}
