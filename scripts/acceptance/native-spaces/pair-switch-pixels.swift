import AppKit
import CoreMedia

/// Only the two known fixture colors may be retained. Samples outside their blend
/// are rejected before copying any bytes out of the small display crop.
enum PairSwitchPixels {
    static let side = 16
    static func fraction(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Double? {
        let observed = [Double(r), Double(g), Double(b)]
        let a = [45.0, 123.0, 204.0], b = [227.0, 139.0, 53.0]
        func linear(_ x: Double) -> Double {
            let v = x / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        func encoded(_ v: Double) -> Double {
            255 * (v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055)
        }
        var answer: (Double, Double)?
        for physical in [false, true] {
            let left = physical ? a.map(linear) : a
            let right = physical ? b.map(linear) : b
            let red = physical ? linear(observed[0]) : observed[0]
            let weight = min(1, max(0, (red - left[0]) / (right[0] - left[0])))
            let error = (0..<3).map {
                let sample = left[$0] + (right[$0] - left[$0]) * weight
                return abs((physical ? encoded(sample) : sample) - observed[$0])
            }.max()!
            if error <= 6, error < (answer?.1 ?? .infinity) { answer = (weight, error) }
        }
        return answer?.0
    }

    static func read(_ sample: CMSampleBuffer) -> (fraction: Double, rgb: Data)? {
        guard let buf = sample.imageBuffer, CVPixelBufferGetPixelFormatType(buf) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(buf) == side, CVPixelBufferGetHeight(buf) == side,
              CVPixelBufferLockBaseAddress(buf, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        guard let bytes = CVPixelBufferGetBaseAddress(buf)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buf)
        guard stride >= side * 4 else { return nil }
        let reference = (r: bytes[2], g: bytes[1], b: bytes[0])
        guard let weight = fraction(reference.r, reference.g, reference.b) else { return nil }
        var rgb = Data(capacity: side * side * 3)
        for y in 0..<side {
            for x in 0..<side {
                let p = bytes + y * stride + x * 4
                guard p[3] == 255, abs(Int(p[2]) - Int(reference.r)) <= 2,
                      abs(Int(p[1]) - Int(reference.g)) <= 2, abs(Int(p[0]) - Int(reference.b)) <= 2 else { return nil }
                rgb.append(p[2]); rgb.append(p[1]); rgb.append(p[0])
            }
        }
        return (weight, rgb)
    }

    /// The caller already checked the Host's code hash, kernel generation and
    /// isolated profile. Every other intersecting surface still goes to physicalTop.
    static func cover(_ row: [String: Any], host: pid_t, patch: CGRect) -> UInt32? {
        guard row[kCGWindowOwnerPID as String] as? pid_t == host,
              row[kCGWindowLayer as String] as? Int == NSWindow.Level.normal.rawValue + 1,
              row[kCGWindowIsOnscreen as String] as? Bool == true,
              row[kCGWindowAlpha as String] as? Double == 1,
              let bounds = row[kCGWindowBounds as String] as? NSDictionary, CGRect(dictionaryRepresentation: bounds) == patch,
              let number = row[kCGWindowNumber as String] as? UInt32, number != 0 else { return nil }
        return number
    }

    struct Series {
        private(set) var frames = [[String: Any]]()
        private var intermediate = [Double]()
        private var prior = 0.0
        private var uncertain = 0
        private var reversed = false
        private var observedStart = false, observedEnd = false
        private var firstTime: Double?, firstChanged: Double?, lastTime: Double?
        private var panel: UInt32?
        mutating func append(progress: Double, data: Data, time: Double, before: UInt32?, after: UInt32?) {
            let interior = (0.06...0.94).contains(progress)
            let bound = before == after && before != nil
            var frame: [String: Any] = ["displayUptime": time, "targetFraction": progress, "sameCover": bound]
            if firstTime == nil { firstTime = time }
            if let lastTime, time <= lastTime { uncertain += 1 }
            lastTime = time
            if progress > 0.06, firstChanged == nil { firstChanged = time }
            if (interior && !bound) || (bound && panel != nil && panel != before) {
                uncertain += 1
            } else {
                if bound { panel = before }
                if interior { intermediate.append(progress) }
                if progress < prior - 0.035 { reversed = true }
                if frames.isEmpty { observedStart = progress < 0.035 && before == nil && after == nil }
                if progress > 0.965 && before == nil && after == nil { observedEnd = true }
                prior = max(prior, progress)
                frame["fixtureRGB8"] = data.base64EncodedString()
            }
            frames.append(frame)
        }
        func receipt(terminated: Bool, down: ClosedRange<Double>?, up: ClosedRange<Double>?, uncertainty: Double?) -> [String: Any] {
            let values = Set(intermediate.map { Int(($0 * 20).rounded()) })
            let spread = (intermediate.max() ?? 0) - (intermediate.min() ?? 0)
            let complete = observedStart && observedEnd && values.count >= 3 && spread >= 0.35
            var afterClick = false
            if let down, let up, let uncertainty, let firstTime, let firstChanged, let lastTime {
                afterClick = (0...0.005).contains(uncertainty) && firstTime + uncertainty < down.lowerBound &&
                    down.upperBound <= up.lowerBound && up.upperBound <= firstChanged - uncertainty && lastTime >= firstChanged
            }
            let status = reversed ? "FAIL" : (terminated || uncertain > 0 || !complete || !afterClick ? "UNKNOWN" : "PASS")
            return ["status": status, "method": "signedHostAndFixtureRestrictedPhysicalCrop",
                    "raster": [side, side], "frames": frames, "intermediateFrames": intermediate.count,
                    "distinctIntermediateBins": values.count, "fractionSpan": spread, "reversed": reversed,
                    "unattributedFrames": uncertain, "uncoveredSource": observedStart, "uncoveredTarget": observedEnd,
                    "afterClick": afterClick]
        }
    }
}
