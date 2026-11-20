import Foundation
import Testing
import NearpaneCore
@testable import NearpaneUI

struct NativeSwitchJournalTests {
    @Test func completedOrUnissuedActionsUnlockAndUnknownSurvivesRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = NativeSwitchJournal(directory: directory)
        for state in [NativeSpaceReply.State.failed, .confirmed, .outcomeUnknown] {
            let request = NativeSpaceCommand(id: UUID(), action: .select, display: "D", source: "1", target: "2")
            try journal.begin(request)
            #expect(throws: (any Error).self) { try journal.begin(request) }
            try journal.finish(request, result: .init(id: request.id, state: state, detail: "", canSwitch: true, canMove: false,
                submittedSteps: state == .failed ? 0 : 1))
            #expect(NativeSwitchJournal(directory: directory).suspended == (state == .outcomeUnknown))
            let data = try Data(contentsOf: directory.appendingPathComponent(request.id.uuidString + ".json"))
            let stored = try JSONDecoder().decode(NativeSwitchJournal.Record.self, from: data)
            #expect(stored.intent.id == request.id && stored.result.state == state)
        }
    }
}
