import Foundation
import SwiftUI

/// Public SwiftUI assistive-technology environment for the isolated native UI
/// runner. Normal applications, release builds and non-CI fixtures keep the OS
/// environment. This enables inspection, not permissions or playback ownership.
public enum NativeVerificationAccessibility {
    public static var isEnabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" &&
            ProcessInfo.processInfo.environment["NEARPANE_ACCEPTANCE_CHECKOUT"] != nil &&
            Bundle.main.bundleIdentifier == "com.holdsnow.nearpane.alpha" &&
            CommandLine.arguments.contains("--native-settings-readback")
        #else
        false
        #endif
    }
}

extension View {
    @MainActor @ViewBuilder
    func nativeVerificationAccessibility() -> some View {
        #if DEBUG
        if NativeVerificationAccessibility.isEnabled {
            environment(\.accessibilityEnabled, true)
        } else {
            self
        }
        #else
        self
        #endif
    }
}
