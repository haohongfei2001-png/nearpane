import Foundation

/// Recorded by the supervising operator only after the owner grants this
/// specific unattended console interval and identifies its two test desktops.
package struct ConsoleSpaceConsent: Codable {
    package let run: UUID
    package let boot, secondaryDisplay, source, target: String
    package let securityID: UInt32
    package let starts, ends: Date
    package let permitsCalibrationAndThreeRoundTrips: Bool

    package func allows(run expected: UUID, boot liveBoot: String, securityID liveID: UInt32,
                        display: String, at now: Date) -> Bool {
        guard !liveBoot.isEmpty, liveID != 0, run == expected, boot == liveBoot, securityID == liveID,
              secondaryDisplay == display, UUID(uuidString: display) != nil, permitsCalibrationAndThreeRoundTrips,
              let a = UInt64(source), a > 0, String(a) == source, let b = UInt64(target),
              b > 0, String(b) == target, a != b else { return false }
        return starts <= now && now < ends && ends.timeIntervalSince(starts) <= 900
    }
}
