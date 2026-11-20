import AVFAudio
import Foundation
import Speech

// stdout is a JSON-lines timeline. The caller saves partial events if a system service stalls.
private func event(_ stage: String, _ fields: [String: Any] = [:]) {
    var payload = fields
    payload["stage"] = stage
    payload["uptimeSeconds"] = ProcessInfo.processInfo.systemUptime
    if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
        FileHandle.standardOutput.write(data + Data([10]))
    }
}

@available(macOS 26, *)
private func statusName(_ status: AssetInventory.Status) -> String {
    switch status {
    case .unsupported: "unsupported"
    case .supported: "supported"
    case .downloading: "downloading"
    case .installed: "installed"
    @unknown default: "unknown"
    }
}

@available(macOS 26, *)
private func run(_ args: [String]) async throws -> Int32 {
    let env = ProcessInfo.processInfo.environment
    guard env["GITHUB_ACTIONS"] == "true", env["RUNNER_ENVIRONMENT"] == "github-hosted",
          env["RUNNER_OS"] == "macOS", env["GITHUB_REPOSITORY"] == "haohongfei2001-png/nearpane" else {
        event("refused-outside-disposable-runner")
        return 7
    }
    guard args == ["--prepare"] || (args.count == 2 && args[0] == "--recognize") else {
        event("invalid-arguments")
        return 2
    }
    let available = SpeechTranscriber.isAvailable
    event("inventory-start", ["transcriberAvailable": available])
    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN")) else {
        event("locale-unsupported")
        return 3
    }
    let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    let modules: [any SpeechModule] = [transcriber, SpeechDetector()]
    let before = await AssetInventory.status(forModules: modules)
    let localeWasInstalled = await SpeechTranscriber.installedLocales.contains(locale)
    event("inventory", ["locale": locale.identifier, "asset": statusName(before), "localeInstalled": localeWasInstalled])
    guard available, before != .unsupported else { return 3 }
    if args == ["--prepare"] {
        if before != .installed {
            event("request-start")
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                event("installation-start")
                try await request.downloadAndInstall()
                event("installation-returned")
            } else {
                event("no-installation-request")
            }
        }
        let after = await AssetInventory.status(forModules: modules)
        let installed = await SpeechTranscriber.installedLocales.contains(locale)
        event("inventory-after", ["asset": statusName(after), "localeInstalled": installed])
        return after == .installed && installed ? 0 : 4
    }
    guard before == .installed && localeWasInstalled else { return 4 }
    // Only the six generated files in the runner's own temporary directory may reach Speech.
    let files = ["01-clean", "01-noise10dB", "02-clean", "02-noise10dB", "03-clean", "03-noise10dB"]
    guard let temporary = env["NEARPANE_SPEECH_FIXTURES"], let runnerTemp = env["RUNNER_TEMP"],
          files.contains(args[1]) else { return 2 }
    let base = URL(fileURLWithPath: temporary, isDirectory: true).resolvingSymlinksInPath()
    let scratch = URL(fileURLWithPath: runnerTemp, isDirectory: true).resolvingSymlinksInPath()
    let fileURL = base.appendingPathComponent(args[1] + ".wav").resolvingSymlinksInPath()
    guard base.path.hasPrefix(scratch.path + "/"), fileURL.deletingLastPathComponent().path == base.path else { return 2 }
    let file = try AVAudioFile(forReading: fileURL)
    let analyzer = SpeechAnalyzer(modules: modules)
    let final = Task { () throws -> (String, Int) in
        var text = ""
        var count = 0
        for try await result in transcriber.results where result.isFinal {
            text += String(result.text.characters)
            count += 1
        }
        return (text, count)
    }
    do {
        event("analysis-start", ["frames": file.length])
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        let (text, count) = try await final.value
        event("analysis-finished", ["finalText": text, "finalCount": count])
        return 0
    } catch {
        final.cancel()
        throw error
    }
}

@main private struct FileProbe {
    static func main() async {
        guard #available(macOS 26, *) else { event("os-unsupported"); exit(5) }
        do { exit(try await run(Array(CommandLine.arguments.dropFirst()))) }
        catch {
            let error = error as NSError
            event("framework-error", ["domain": error.domain, "code": error.code])
            exit(8)
        }
    }
}
