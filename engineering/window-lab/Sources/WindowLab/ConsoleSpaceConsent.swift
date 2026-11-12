import Foundation

/// Recorded by the supervising operator only after the owner grants this
/// specific unattended console interval and identifies its two test desktops.
package struct ConsoleSpaceConsent: Codable {
    package let run: UUID
    package let boot, secondaryDisplay, source, target: String
    package let securityID: UInt32
    package let starts, ends: Date
    package let permitsCalibrationAndThreeRoundTrips: Bool
    package let permitsSingleWindowFullscreen: Bool?
    package let permitsTemporarySecondaryFocus: Bool?

    /// Only consulted after allows() verifies the owner, procedure, display and time window.
    package func acceptsFocusRegion(_ region: String) -> Bool {
        region == "secondary" || (region == "protected-main" && permitsTemporarySecondaryFocus == true)
    }

    package func allows(run expected: UUID, boot liveBoot: String, securityID liveID: UInt32,
                        display: String, at now: Date, fullscreenOnly: Bool = false) -> Bool {
        guard !liveBoot.isEmpty, liveID != 0, run == expected, boot == liveBoot, securityID == liveID,
              secondaryDisplay == display, UUID(uuidString: display) != nil,
              let a = UInt64(source), a > 0, String(a) == source,
              starts <= now, now < ends, ends.timeIntervalSince(starts) <= 900 else { return false }
        if fullscreenOnly {
            return permitsSingleWindowFullscreen == true && !permitsCalibrationAndThreeRoundTrips && target.isEmpty
        }
        guard permitsSingleWindowFullscreen != true, permitsCalibrationAndThreeRoundTrips,
              let b = UInt64(target), b > 0, String(b) == target else { return false }
        return a != b
    }
}
