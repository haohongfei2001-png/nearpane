import Foundation
import Testing
import NearpaneCore
@testable import NearpaneUI

@Suite("Admission reader scope") struct AdmissionReaderTests {
    private let session = UUID()
    private let birth = AdmissionBirth(pid: 140, parent: 120, start: 1000)
    private var id: ManagedWindowID { .init(pid: birth.pid, launch: birth.start, number: 35, element: UUID()) }
    private func member(_ id: ManagedWindowID, index: Int = 1) -> AdmissionFixture.Member {
        .init(index: index, id: id, minimum: .init(width: 120, height: 80), identifier: session.uuidString + "/" + id.element.uuidString)
    }
    private func owner(_ entries: [AdmissionFixture.Member]) -> AdmissionFixture.Owner {
        let tokens = Dictionary(entries.map { ($0.identifier,UUID()) }, uniquingKeysWith: { a,_ in a })
        return .init(session: session, owner: birth, revision: 1, uptime: 12,
                     members: entries, frames: entries.map { _ in .init(width: 200,height: 150) }, editTokens: tokens, editing: false)
    }
    @Test func verifiesEveryGenerationAndRejectsReusedNumberAndMissedHeartbeat() {
        let m = member(id)
        #expect(AdmissionFixture.valid(owner([m]), now: 13))
        #expect(!AdmissionFixture.valid(owner([m]), now: 14))
        let recycled = ManagedWindowID(pid: birth.pid, launch: birth.start + 1, number: m.id.number, element: m.id.element)
        #expect(!AdmissionFixture.valid(owner([member(recycled)]), now: 13))
        let duplicate = ManagedWindowID(pid: birth.pid, launch: birth.start, number: m.id.number, element: UUID())
        #expect(!AdmissionFixture.valid(owner([m,member(duplicate,index:2)]), now: 13))
        let wrong = AdmissionFixture.Member(index: 1, id: m.id, minimum: m.minimum, identifier: UUID().uuidString)
        #expect(!AdmissionFixture.valid(owner([wrong]), now: 13))
    }

    @Test @MainActor func acceptanceListNeverFallsBackToWorkspaceOrAnUnlistedProcess() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = WindowAdmissionReader(support: dir, fixtureOnly: true)
        #expect(reader.applications().isEmpty)
        let app = AdmissionApplication(pid: getpid(),launch:100,bundle:"synthetic.unlisted",name:"synthetic")
        await #expect(throws: (any Error).self) { try await reader.windows(app) }
        await #expect(throws: (any Error).self) {
            try await reader.inspect(app, selected: [.init(id: UUID(),number:35,index:1)])
        }
        #expect(reader.safeguards(app).exclusive == nil)
        #expect(reader.storedLayout(app) == nil)
    }

    @Test func aMissingOrUnverifiedJournalCannotAdmitAnExistingLayout() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root,withIntermediateDirectories: false)
        defer { try? fm.removeItem(at:root) }
        let m = member(id), o = owner([m])
        let fixture = AdmissionFixture(root: root,dir: root,owner:o,
            run:.init(session:session,parent:birth,productManagement:true,screens:.init(secondary:"secondary")),
            prefs:.init(session:session,blockedReason:nil))
        try Data(#"{"blocked":false,"trusted":true}"#.utf8).write(to:root.appendingPathComponent("status.json"))
        #expect(fixture.safeguards().recoveryClear == true)
        try Data("{}".utf8).write(to:root.appendingPathComponent("layout.json"))
        #expect(fixture.safeguards().recoveryClear == false)
        try Data("{}".utf8).write(to:root.appendingPathComponent("journal.json"))
        #expect(fixture.safeguards().recoveryClear == nil)
        #expect(fixture.storedLayout() == nil)
    }
}
