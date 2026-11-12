import CoreAudio
import Testing
@testable import NearpaneVoice

struct VoiceInputRouteTests {
    @Test func defaultMustBeAliveAndHaveAnInputStream() {
        let size = UInt32(MemoryLayout<AudioStreamID>.size)
        #expect(VoiceInputRoute.read(defaultDevice: { 2 }, alive: { _ in 1 }, streamBytes: { _ in size }) == .available)
        #expect(VoiceInputRoute.read(defaultDevice: { 2 }, alive: { _ in 0 }, streamBytes: { _ in size }) == .disconnected)
        #expect(VoiceInputRoute.read(defaultDevice: { 2 }, alive: { _ in 1 }, streamBytes: { _ in 0 }) == .disconnected)
        #expect(VoiceInputRoute.read(defaultDevice: { 0 }, alive: { _ in nil }, streamBytes: { _ in nil }) == .disconnected)
    }

    @Test func unknownAndChangingRoutesDoNotClaimHardwareIsMissingOrReady() {
        var route: AudioDeviceID = 8
        #expect(VoiceInputRoute.read(defaultDevice: { route }, alive: { _ in 1 }, streamBytes: { _ in route = 9; return 4 }) == .unknown)
        #expect(VoiceInputRoute.read(defaultDevice: { nil }, alive: { _ in nil }, streamBytes: { _ in nil }) == .unknown)
        #expect(VoiceInputRoute.read(defaultDevice: { 2 }, alive: { _ in nil }, streamBytes: { _ in 4 }) == .unknown)
        #expect(VoiceInputRoute.read(defaultDevice: { 2 }, alive: { _ in 1 }, streamBytes: { _ in nil }) == .unknown)
        #expect(VoiceInputRoute.read(defaultDevice: { 2 }, alive: { _ in 1 }, streamBytes: { _ in 1 }) == .unknown)
    }
    @MainActor @Test func defaultSwitchRefreshesVisibleSettingsAndLastCloseRemovesListener() async throws {
        var registrations: [Bool] = []
        let monitor = VoiceInputRouteObservation { add in registrations.append(add); return true }
        let first = monitor.changes(), second = monitor.changes()
        #expect(registrations == [true])
        var sample = first.makeAsyncIterator()
        _ = try #require(await sample.next())
        // A default changes while both input devices remain plugged in.
        monitor.changed()
        _ = try #require(await sample.next())
        func waitUntilCancelled(_ stream: AsyncStream<Void>) -> Task<Void, Never> {
            Task { for await _ in stream {} }
        }
        let closed = waitUntilCancelled(first)
        closed.cancel(); await closed.value
        #expect(registrations == [true])
        let last = waitUntilCancelled(second)
        last.cancel(); await last.value
        for _ in 0..<100 where registrations == [true] { await Task.yield() }
        #expect(registrations == [true, false])
    }

}
