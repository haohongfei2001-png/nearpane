// Press the voice controls of the installed App in an executable-bound disposable profile.
import AppKit
import ApplicationServices

private struct Refusal: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}
private struct Record: Decodable {
    struct State: Decodable {
        var pid: Int32
        var windowID: Int
        var visible: Bool
        var voice: String
        var hasTranscript: Bool
        var micAuthorization: Int
        var speechAuthorization: Int
    }
    var kind: String
    var state: State
}
@MainActor private final class VoiceReview {
    let events: URL
    let output: URL
    let audio: URL
    let host: NSRunningApplication
    let product: AXUIElement
    var evidence: [String: Any] = [:]

    init(events: URL, output: URL, audio: URL) throws {
        let runs = NSRunningApplication.runningApplications(withBundleIdentifier: "com.holdsnow.nearpane.alpha")
            .filter { $0.bundleURL?.path == "/Applications/Nearpane.app" }
        guard runs.count == 1, let host = runs.first, AXIsProcessTrusted(),
              UUID(uuidString: events.deletingLastPathComponent().lastPathComponent) != nil,
              events.lastPathComponent.hasPrefix("events-"), events.pathExtension == "jsonl" else {
            throw Refusal("The isolated signed host and observer must be present")
        }
        self.host = host
        self.product = AXUIElementCreateApplication(host.processIdentifier)
        self.events = events
        self.output = output
        self.audio = audio
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
    }

    func records() throws -> [Record] {
        let lines = try Data(contentsOf: events).split(separator: 10)
        let records = lines.compactMap { try? JSONDecoder().decode(Record.self, from: Data($0)) }
        guard !records.isEmpty, records.allSatisfy({ $0.state.pid == host.processIdentifier }),
              !host.isTerminated else { throw Refusal("Live process differs from the scoped recorder") }
        return records
    }

    func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success ? value : nil
    }

    func press(_ label: String) throws {
        guard let latest = try records().last?.state, latest.visible, latest.windowID > 0,
              let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, UInt32(latest.windowID)) as? [[String:Any]],
              let bounds = info.first?[kCGWindowBounds as String] as? NSDictionary,
              let target = CGRect(dictionaryRepresentation: bounds) else { throw Refusal("Isolated sidebar unavailable") }
        func frame(_ node: AXUIElement) -> CGRect? {
            guard let p = attribute(node,kAXPositionAttribute), let s = attribute(node,kAXSizeAttribute),
                  CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero, size = CGSize.zero
            guard AXValueGetValue(p as! AXValue,.cgPoint,&point), AXValueGetValue(s as! AXValue,.cgSize,&size) else { return nil }
            return CGRect(origin:point,size:size)
        }
        var nodes = (attribute(product,kAXWindowsAttribute) as? [AXUIElement] ?? []).filter {
            frame($0).map { abs($0.midX-target.midX) < 2 && abs($0.height-target.height) < 2 } == true
        }
        guard nodes.count == 1 else { throw Refusal("Exact installed sidebar has no unique AX window") }
        var buttons = [AXUIElement]()
        while let node = nodes.popLast() {
            if attribute(node,kAXRoleAttribute) as? String == kAXButtonRole,
               [kAXTitleAttribute,kAXDescriptionAttribute,kAXHelpAttribute].contains(where: { attribute(node,$0) as? String == label }),
               attribute(node,kAXEnabledAttribute) as? Bool != false { buttons.append(node) }
            nodes.append(contentsOf: attribute(node,kAXChildrenAttribute) as? [AXUIElement] ?? [])
        }
        guard buttons.count == 1 else { throw Refusal("Voice control is not uniquely actionable: " + label) }
        let code = AXUIElementPerformAction(buttons[0], kAXPressAction as CFString)
        guard code == .success else { throw Refusal("Voice AXPress returned " + String(code.rawValue)) }
    }

    func persist() throws {
        let data = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted,.sortedKeys])
        try data.write(to: output.appendingPathComponent("result.json"),options: .atomic)
    }

    func waitFor(_ state: Set<String>, seconds: Double) async throws -> Record.State? {
        let end = ContinuousClock.now.advanced(by: .seconds(seconds))
        repeat {
            if let record = try records().last, state.contains(record.state.voice) { return record.state }
            try await Task.sleep(for: .milliseconds(140))
        } while ContinuousClock.now < end
        return nil
    }

    func run() async throws {
        let initial = try records()
        guard let first = initial.last?.state, first.visible, first.voice == "paused", first.micAuthorization == 3,
              first.hasTranscript == false else { throw Refusal("Requires an authorized microphone and empty paused profile") }
        let camera = events.deletingLastPathComponent().appendingPathComponent("capture-panel")
        guard FileManager.default.isExecutableFile(atPath: camera.path) else {
            throw Refusal("Wait for the isolated panel observer to finish compiling")
        }
        evidence["microphoneAuthorized"] = true
        evidence["speechAuthorization"] = first.speechAuthorization
        evidence["profile"] = "isolated, opened by Launch Services from /Applications"
        var didStart = false
        do {
            try press("开始或恢复收音")
            evidence["pressedStart"] = true
            didStart = true
            guard let live = try await waitFor(["standby","speaking"], seconds: 10) else {
                throw Refusal("The installed microphone UI did not enter standby or speaking")
            }
            let shot = Process()
            shot.executableURL = camera
            shot.arguments = [String(host.processIdentifier),String(live.windowID),"/Applications/Nearpane.app/Contents/MacOS/NearpaneHost",output.appendingPathComponent("voice-enabled.png").path]
            try shot.run()
            shot.waitUntilExit()
            evidence["enabledPanelCaptured"] = shot.terminationStatus == 0
            guard let sound = NSSound(contentsOf: audio, byReference: false) else { throw Refusal("Fixture audio unavailable") }
            sound.volume = 0.35
            guard sound.play() else { throw Refusal("Fixture playback failed") }
            evidence["playedLocalPhrase"] = true
            try await Task.sleep(for: .seconds(max(0.5,sound.duration)))
            _ = try await waitFor(["standby"], seconds: 8)
            let end = ContinuousClock.now.advanced(by: .seconds(4))
            while try records().last?.state.hasTranscript == false && ContinuousClock.now < end {
                try await Task.sleep(for: .milliseconds(200))
            }
            try press("暂停收音")
            evidence["pressedPause"] = true
            guard let final = try await waitFor(["paused"],seconds: 6) else { throw Refusal("Pause unconfirmed") }
            didStart = false
            let observed = try records().dropFirst(initial.count)
            evidence["states"] = Set(observed.map { $0.state.voice }).sorted()
            evidence["startEvent"] = observed.contains { $0.kind == "userStart" }
            evidence["pauseEvent"] = observed.contains { $0.kind == "userPause" }
            evidence["hasTranscriptAfterPause"] = final.hasTranscript
            try persist()
        } catch {
            if didStart, let state = try? await waitFor(["speaking","standby","paused"],seconds: 6), state.voice != "paused" {
                try? press("暂停收音")
                _ = try? await waitFor(["paused"],seconds: 5)
            }
            evidence["issue"] = error.localizedDescription
            evidence["finalState"] = (try? records().last?.state.voice) ?? "unavailable"
            try persist()
            throw error
        }
    }
}
@main struct Entry {
    @MainActor static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count == 3 else { throw Refusal("Expected isolated event journal, new output directory and local phrase") }
            let review = try VoiceReview(events:URL(fileURLWithPath:args[0]),output:URL(fileURLWithPath:args[1],isDirectory:true),audio:URL(fileURLWithPath:args[2]))
            try await review.run()
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription+"\n").utf8))
            exit(2)
        }
    }
}
