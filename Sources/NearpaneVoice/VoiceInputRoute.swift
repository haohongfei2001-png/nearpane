import CoreAudio
import Foundation

/// Metadata of the system default used by Saytile's unpinned AVAudioEngine.
/// This never opens an audio unit, reads samples, or asks for TCC.
enum VoiceInputRoute: String {
    case available, disconnected, unknown

    var label: String {
        switch self {
        case .available: "系统默认输入设备已连接"
        case .disconnected: "没有已连接的系统默认输入，请检查「系统设置 → 声音 → 输入」"
        case .unknown: "暂时无法确认系统默认输入，请重新检查"
        }
    }

    static func current() -> Self {
        read(defaultDevice: { scalar(kAudioHardwarePropertyDefaultInputDevice, on: AudioObjectID(kAudioObjectSystemObject)) },
             alive: { scalar(kAudioDevicePropertyDeviceIsAlive, on: $0) }, streamBytes: { device in
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &bytes) == noErr else { return nil }
            return bytes
        })
    }

    static func read(defaultDevice: () -> AudioDeviceID?, alive: (AudioDeviceID) -> UInt32?,
                     streamBytes: (AudioDeviceID) -> UInt32?) -> Self {
        guard let device = defaultDevice() else { return .unknown }
        guard device != kAudioObjectUnknown else { return .disconnected }
        guard let live = alive(device), let bytes = streamBytes(device), defaultDevice() == device,
              bytes.isMultiple(of: UInt32(MemoryLayout<AudioStreamID>.size)) else { return .unknown }
        return live != 0 && bytes > 0 ? .available : .disconnected
    }

    private static func scalar(_ selector: AudioObjectPropertySelector, on device: AudioObjectID) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              size == MemoryLayout<UInt32>.size else { return nil }
        return value
    }

}

/// A default-device switch need not connect or disconnect any hardware.
/// CoreAudio retains no view or Swift object pointer. Use one C listener while
/// at least one Settings view is subscribed, matching the same callback on removal.
@MainActor
final class VoiceInputRouteObservation {
    static let shared = VoiceInputRouteObservation()

    private var listeners: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var registered = false
    private let registration: (Bool) -> Bool

    init(registration: @escaping (Bool) -> Bool = VoiceInputRouteObservation.register) {
        self.registration = registration
    }

    func changes() -> AsyncStream<Void> {
        let token = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        listeners[token] = continuation
        if !registered { registered = registration(true) }
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.remove(token) }
        }
        // Sample after subscribing to close the initial read/subscribe gap.
        continuation.yield()
        return stream
    }

    func changed() {
        for listener in listeners.values { listener.yield() }
    }

    private func remove(_ token: UUID) {
        listeners.removeValue(forKey: token)
        if listeners.isEmpty && registered { registered = !registration(false) }
    }

    private nonisolated static func register(_ add: Bool) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        if add { return AudioObjectAddPropertyListener(system, &address, voiceDefaultInputChanged, nil) == noErr }
        return AudioObjectRemovePropertyListener(system, &address, voiceDefaultInputChanged, nil) == noErr
    }
}

private func voiceDefaultInputChanged(_ device: AudioObjectID, _ count: UInt32,
                                      _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
                                      _ context: UnsafeMutableRawPointer?) -> OSStatus {
    Task { @MainActor in VoiceInputRouteObservation.shared.changed() }
    return noErr
}
