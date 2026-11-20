// Operate only the production voice control of the exact installed process supplied by the profile owner.
import AppKit
import AVFoundation
import ApplicationServices
import CoreAudio

private struct Refusal: LocalizedError {
    var errorDescription: String?
    init(_ reason: String) { errorDescription = reason }
}

private func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success else { return nil }
    return value
}

private func scalar(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<UInt32>.size), result: UInt32 = 0
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr else { return nil }
    return result
}

private func transport(_ selector: AudioObjectPropertySelector) throws -> String {
    guard let device = scalar(AudioObjectID(kAudioObjectSystemObject), selector), device != kAudioObjectUnknown,
          let type = scalar(device, kAudioDevicePropertyTransportType),
          [kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeBluetooth,
           kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeThunderbolt,
           kAudioDeviceTransportTypePCI, kAudioDeviceTransportTypeFireWire,
           kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort].contains(type) else {
        throw Refusal("The selected physical input or playback route could not be confirmed")
    }
    return withUnsafeBytes(of: type.bigEndian) { String(decoding: $0, as: UTF8.self) }
}

@MainActor private final class Trial {
    let host: NSRunningApplication
    let product: AXUIElement
    let result: URL
    var events = [[String: Any]]()
    let start = ProcessInfo.processInfo.systemUptime
    var receipt: [String: Any] = [:]
    var started = false

    init(pid: pid_t, result: URL) throws {
        guard AXIsProcessTrusted(), let app = NSRunningApplication(processIdentifier: pid),
              app.bundleIdentifier == "com.holdsnow.nearpane.alpha",
              app.bundleURL?.path == "/Applications/Nearpane.app",
              app.executableURL?.path == "/Applications/Nearpane.app/Contents/MacOS/NearpaneHost" else {
            throw Refusal("Installed process or observer Accessibility permission is unavailable")
        }
        host = app
        product = AXUIElementCreateApplication(pid)
        self.result = result
    }

    func event(_ name: String) {
        events.append(["kind": name, "offsetSeconds": ProcessInfo.processInfo.systemUptime - start])
    }

    func control() throws -> (node: AXUIElement, label: String, value: String, enabled: Bool) {
        guard !host.isTerminated else { throw Refusal("The isolated Host exited") }
        var nodes = attribute(product, kAXWindowsAttribute) as? [AXUIElement] ?? []
        var buttons = [AXUIElement]()
        while let node = nodes.popLast() {
            if attribute(node, kAXIdentifierAttribute) as? String == "voice-capture-toggle",
               attribute(node, kAXRoleAttribute) as? String == kAXButtonRole {
                buttons.append(node)
            } else {
                nodes.append(contentsOf: attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [])
            }
        }
        if buttons.count > 1 {
            let main = CGDisplayBounds(CGMainDisplayID())
            buttons = buttons.filter { node in
                guard let point = attribute(node, kAXPositionAttribute), CFGetTypeID(point) == AXValueGetTypeID() else { return false }
                var origin = CGPoint.zero
                return AXValueGetValue(point as! AXValue, .cgPoint, &origin) && main.contains(origin)
            }
        }
        guard buttons.count == 1, let button = buttons.first else {
            throw Refusal("No unique production sidebar voice button")
        }
        let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].compactMap { attribute(button, $0) as? String }
        guard let label = labels.first(where: { ["开始或恢复收音", "暂停收音"].contains($0) }) else {
            throw Refusal("Unexpected production voice button")
        }
        return (button, label, attribute(button, kAXValueAttribute) as? String ?? "", attribute(button, kAXEnabledAttribute) as? Bool == true)
    }

    func press(_ label: String) throws {
        let button = try control()
        guard button.label == label, button.enabled,
              AXUIElementPerformAction(button.node, kAXPressAction as CFString) == .success else {
            throw Refusal("Voice button did not accept " + label)
        }
    }

    func wait(_ seconds: Double, _ condition: () throws -> Bool) async throws {
        let until = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            guard !host.isTerminated else { throw Refusal("The isolated Host exited") }
            if (try? condition()) == true { return }
            try await Task.sleep(for: .milliseconds(40))
        } while ProcessInfo.processInfo.systemUptime < until
        throw Refusal("Timed out waiting for the installed voice control")
    }

    func run(_ stimulus: URL) async throws {
        receipt["physicalInputTransport"] = try transport(kAudioHardwarePropertyDefaultInputDevice)
        receipt["physicalOutputTransport"] = try transport(kAudioHardwarePropertyDefaultOutputDevice)
        let player = try AVAudioPlayer(contentsOf: stimulus)
        player.volume = 0.65
        guard player.duration > 0, player.duration <= 8, player.prepareToPlay() else { throw Refusal("Cannot prepare the local short phrase") }
        receipt["stimulusSeconds"] = player.duration
        receipt["playbackVolume"] = player.volume
        defer { player.stop() }
        try await wait(9) {
            let button = try self.control()
            return button.label == "开始或恢复收音" && button.value == "暂停" && button.enabled
        }
        try press("开始或恢复收音")
        started = true
        event("startPressed")
        try await wait(12) {
            let button = try control()
            return button.label == "暂停收音" && ["待命", "正在识别"].contains(button.value)
        }
        event("captureReady")
        guard player.play() else { throw Refusal("Short phrase playback failed") }
        event("stimulusStarted")
        let timeout = ProcessInfo.processInfo.systemUptime + player.duration + 1
        while player.isPlaying {
            guard ProcessInfo.processInfo.systemUptime < timeout else { throw Refusal("Short phrase playback did not finish") }
            try await Task.sleep(for: .milliseconds(40))
        }
        event("stimulusFinished")
        // The file may end immediately after a consonant. Allow the hardware callback
        // and resampler to enqueue their tail, then let normal Pause drain the worker.
        try await Task.sleep(for: .milliseconds(650))
        try press("暂停收音")
        event("pausePressed")
        try await wait(9) {
            let button = try self.control()
            return button.label == "开始或恢复收音" && button.value == "暂停" && button.enabled
        }
        started = false
        event("pauseObserved")
    }

    func save(issue: String?) throws {
        if let issue { receipt["issue"] = issue }
        receipt["events"] = events
        receipt["pid"] = host.processIdentifier
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: result, options: .atomic)
    }
}

@main struct Entry {
    @MainActor static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count == 3, let pid = pid_t(args[0]) else { throw Refusal("Expected installed PID, fixture WAV and receipt path") }
            let trial = try Trial(pid: pid, result: URL(fileURLWithPath: args[2]))
            do {
                try await trial.run(URL(fileURLWithPath: args[1]))
                try trial.save(issue: nil)
            } catch {
                if trial.started, (try? trial.control().label) == "暂停收音" {
                    try? trial.press("暂停收音")
                }
                try trial.save(issue: error.localizedDescription)
                throw error
            }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(2)
        }
    }
}
