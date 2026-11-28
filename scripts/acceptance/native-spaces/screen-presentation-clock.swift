import CoreMedia
import Foundation

/// Maps the compositor's mach displayTime and its host-clock PTS onto the same
/// systemUptime timeline as the posted input and independent WindowServer reads.
struct PreviewClock: Encodable {
    enum Failure: String, Error { case machTimebaseUnavailable, hostClockCalibrationUnavailable }

    let frameTimingVersion = 2
    let uptime: Double, uncertainty: Double, machOffset: Double, hostOffset: Double
    let denominator: UInt32, numerator: UInt32

    static func read() throws -> Self {
        var scale = mach_timebase_info_data_t()
        guard mach_timebase_info(&scale) == KERN_SUCCESS, scale.denom > 0 else { throw Failure.machTimebaseUnavailable }
        let begin = ProcessInfo.processInfo.systemUptime
        let ticks = mach_absolute_time()
        let host = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        let end = ProcessInfo.processInfo.systemUptime
        let mid = (begin + end) / 2
        let mach = Double(ticks) * Double(scale.numer) / Double(scale.denom) / 1e9
        guard end - begin <= 0.01, host.isFinite, mach.isFinite else { throw Failure.hostClockCalibrationUnavailable }
        return Self(uptime:mid, uncertainty:(end - begin) / 2, machOffset:mid - mach, hostOffset:mid - host,
                    denominator:scale.denom, numerator:scale.numer)
    }

    // Early delivery is usable only when both native clocks agree about the outstanding presentation.
    static func presentationBounds(display: Double?, pts: Double?, callback: Double) -> ClosedRange<Double>? {
        guard let t = display ?? pts, t.isFinite, callback.isFinite, t > 0, callback - t <= 1 else { return nil }
        if t > callback {
            guard t - callback <= 1.0 / 60, let display, let pts, pts.isFinite, abs(display - pts) <= 0.001 else { return nil }
        }
        return min(t,callback)...max(t,callback)
    }

    func mapped(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(numerator) / Double(denominator) / 1e9 + machOffset
    }
}
