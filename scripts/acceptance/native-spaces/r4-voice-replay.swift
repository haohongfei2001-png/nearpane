// File-only analysis of a known stimulus and its temporary microphone journal.
// No audio unit/player, device permission, asset reservation, or download.
import AVFoundation
import Foundation
import Speech

private enum InputError: Error { case format, noLocalModel, conversion }

private func fingerprint(_ file: URL) throws -> [[Double]] {
    let source = try AVAudioFile(forReading: file)
    let format = source.processingFormat
    guard format.sampleRate == 16000, format.channelCount == 1, source.length >= 3200, source.length <= 16 * 16000,
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(source.length)) else { throw InputError.format }
    try source.read(into: buffer)
    guard let samples = buffer.floatChannelData?[0] else { throw InputError.conversion }
    // 20 ms Hann windows every 10 ms. Compare changes within each log-energy
    // band; a stationary difference in the speaker/microphone response cancels.
    let bands = [180.0, 250, 350, 490, 680, 950, 1320, 1850, 2580, 3600, 4650]
    let window = (0..<320).map { 0.5 - 0.5 * cos(2 * .pi * Double($0) / 319) }
    let coeff = bands.map { 2 * cos(2 * .pi * $0 / 16000) }
    return stride(from: 0, through: Int(buffer.frameLength) - 320, by: 160).map { start in
        let frame = (0..<320).map { Double(samples[start + $0]) * window[$0] }
        return coeff.map { c in
            var q1 = 0.0, q2 = 0.0
            for sample in frame {
                let q = sample + c * q1 - q2
                q2 = q1
                q1 = q
            }
            return log(max(1e-12, q1 * q1 + q2 * q2 - c * q1 * q2))
        }
    }
}

private func alignment(_ reference: [[Double]], _ capture: [[Double]]) -> [String: Any] {
    let n = reference.count
    let tail = n / 3..<max(n / 3 + 1, n - 8)
    func correlate(_ span: Range<Int>, at lag: Int) -> Double? {
        let lower = max(span.lowerBound, -lag), upper = min(span.upperBound, capture.count - lag)
        guard upper - lower >= max(6, span.count * 9 / 10) else { return nil }
        var total = 0.0, weighted = 0
        for band in reference[0].indices {
            var x = 0.0, y = 0.0, xx = 0.0, yy = 0.0, xy = 0.0
            for i in lower..<upper {
                let a = reference[i][band], b = capture[i + lag][band]
                x += a; y += b; xx += a * a; yy += b * b; xy += a * b
            }
            let count = Double(upper - lower)
            let denom = sqrt(max(0, xx - x * x / count) * max(0, yy - y * y / count))
            if denom > 0.0001 { total += (xy - x * y / count) / denom; weighted += 1 }
        }
        return weighted == 0 ? nil : total / Double(weighted)
    }
    let lags = (-min(45, n / 2)...max(1, capture.count - n + 45))
    let candidates = lags.compactMap { lag in correlate(tail, at: lag).map { (lag, $0) } }
    guard let (lag, best) = candidates.max(by: { $0.1 < $1.1 }) else { return ["status": "insufficient overlap"] }
    let alternate = candidates.filter { abs($0.0 - lag) > 18 }.map(\.1).max()
    let thirds = [0..<max(1,n / 3), n / 3..<max(n / 3 + 1, 2 * n / 3), (2 * n / 3)..<n]
    let scores: [Any] = thirds.map { correlate($0, at: lag) as Any? ?? NSNull() }
    return ["lagSeconds": Double(lag) / 100, "fitFromOneThirdToTail": best,
            "bestDistantLagScore": alternate as Any? ?? NSNull(), "thirdsAtSameLag": scores,
            "referenceSeconds": Double(n) / 100, "captureSeconds": Double(capture.count) / 100]
}

private func fileRecognition(_ url: URL) async throws -> String {
    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .init(identifier: "zh-CN")),
          await SpeechTranscriber.installedLocales.contains(locale) else { throw InputError.noLocalModel }
    let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    let analyzer = SpeechAnalyzer(modules: [transcriber, SpeechDetector()])
    let final = Task {
        var text = ""
        for try await result in transcriber.results where result.isFinal { text += String(result.text.characters) }
        return text
    }
    do {
        try await analyzer.start(inputAudioFile: AVAudioFile(forReading: url), finishAfterFile: true)
        return try await final.value
    } catch {
        final.cancel()
        throw error
    }
}

@main struct FileCalibration {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count == 2 else { throw InputError.format }
            let source = URL(fileURLWithPath: args[0]), recorded = URL(fileURLWithPath: args[1])
            var report: [String: Any] = ["alignment": alignment(try fingerprint(source), try fingerprint(recorded))]
            for (key, url) in [("clean", source), ("captured", recorded)] {
                do { report[key] = try await fileRecognition(url) }
                catch { report[key + "Unavailable"] = true }
            }
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            // A private pipe directly into the runner, which immediately masks non-fixture text.
            FileHandle.standardOutput.write(data)
        } catch { exit(2) }
    }
}
