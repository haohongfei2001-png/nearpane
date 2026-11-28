import Foundation
@testable import NearpaneUI
import Testing

struct MissionControlReaderSchedulingTests {
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0, calls = 0, maximum = 0
        private var usedMain = false

        func sample() -> (MissionControlVisibility, String) {
            lock.lock()
            active += 1; calls += 1; maximum = max(maximum, active)
            usedMain = usedMain || Thread.isMainThread
            lock.unlock()
            // Represent bounded synchronous AX IPC. Concurrent callers must
            // suspend without sending simultaneous reads through the Dock state.
            Thread.sleep(forTimeInterval: 0.01)
            lock.lock(); active -= 1; lock.unlock()
            return (.ordinary, "test-observation")
        }

        func result() -> (calls: Int, maximum: Int, usedMain: Bool) {
            lock.lock(); defer { lock.unlock() }
            return (calls, maximum, usedMain)
        }
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func concurrentReadersRunFreshSerialSamplesOffMain() async {
        let probe = Probe(), reader = MissionControlVisibilityReader(sample: { probe.sample() })
        let readings = await withTaskGroup(of: MissionControlVisibilityReader.Reading.self) { group in
            for _ in 0..<6 { group.addTask { await reader.read() } }
            var values = [MissionControlVisibilityReader.Reading]()
            for await value in group { values.append(value) }
            return values.sorted { $0.startUptime < $1.startUptime }
        }
        let result = probe.result()
        #expect(result.calls == 6)
        #expect(result.maximum == 1)
        #expect(!result.usedMain)
        #expect(readings.allSatisfy { $0.visibility == .ordinary && $0.evidence == "test-observation" && $0.endUptime > $0.startUptime })
        for index in readings.indices.dropFirst() {
            #expect(readings[index].startUptime >= readings[index - 1].endUptime)
        }
    }
}
