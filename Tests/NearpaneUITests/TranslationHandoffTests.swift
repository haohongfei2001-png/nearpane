import Foundation
import NearpaneCore
import Testing
@testable import NearpaneUI
#if canImport(Translation)
import Translation
#endif

@MainActor struct TranslationHandoffTests {
    @Test func durableHandoffSurvivesRestartAndStaysInItsGeneration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = TranslationInbox(support: root)
        let a = UUID(), b = UUID()
        let early = try TranslationRequest("synthetic early term", generation: nil)
        let later = try TranslationRequest("synthetic next term", generation: b)
        try inbox.append(early); try inbox.append(later)
        #expect(try TranslationInbox(support: root).pending(for: a) == [early])
        #expect(try inbox.pending(for: b) == [later])
        try inbox.finish(early)
        #expect(try inbox.pending(for: a).isEmpty)
        #expect(throws: (any Error).self) { try TranslationRequest("   ", generation: a) }
        #expect(throws: (any Error).self) { try TranslationRequest(String(repeating: "中", count: 22_000), generation: a) }
    }

    @Test func wordCommitIsIdempotentVersionedAndReadsLegacy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let note = SidebarNotebook(directory: root)
        #expect(note.edit { $0.memo = "synthetic memo"; $0.words.append(.init(source:"legacy",translation:"旧",language:"zh-Hans")) })
        let one = try TranslationRequest("Cafe\u{301}", generation: UUID())
        let saved = try note.commit(one, answer: "咖啡馆", from:"fr", to:"zh-Hans", provider:"fixture/1")
        #expect(try note.commit(one, answer:"duplicated callback", from:"fr", to:"zh-Hans", provider:"fixture/1") == saved)
        let two = try TranslationRequest(" CAFÉ ", generation: one.generation)
        _ = try note.commit(two, answer:"咖啡厅", from:"fr", to:"zh-Hans", provider:"fixture/1")
        let three = try TranslationRequest("café", generation: one.generation)
        _ = try note.commit(three, answer:"咖啡馆", from:"fr", to:"zh-Hans", provider:"fixture/2")
        let reopened = SidebarNotebook(directory: root)
        #expect(reopened.contents.words.count == 3 && reopened.contents.memo == "synthetic memo")
        #expect(try reopened.diskWord(for: two.id)?.sourceSHA256 == two.hash)
        #expect(try reopened.diskWord(for: three.id)?.providerVersion == "fixture/2")
    }

    #if canImport(Translation)
    @available(macOS 26, *)
    @Test func coldHostConsumesRecoveredRequestWithActualInstalledFrameworkAndNoPanel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let generation = UUID(), note = SidebarNotebook(directory: root.appendingPathComponent("notebook"))
        let req = try TranslationRequest("The blue bicycle", generation: generation)
        let inbox = TranslationInbox(support: root)
        try inbox.append(req)
        let service = SelectionTranslation(support: root)
        let available = await LanguageAvailability().status(from: .init(identifier:"en"), to: .init(identifier:"zh-Hans"))
        service.bind(notebook: note, generation: generation)
        await service.waitForRequests()
        let saved = try SidebarNotebook(directory: root.appendingPathComponent("notebook")).diskWord(for: req.id)
        #expect(try inbox.pending(for: generation).isEmpty)
        #expect((saved != nil) == (available == .installed))
        if let saved {
            #expect(!saved.translation.isEmpty && saved.sourceSHA256 == req.hash && saved.sourceLanguage == "en" && saved.committedAt != nil)
        }
        if let output = ProcessInfo.processInfo.environment["NEARPANE_P4_TRANSLATION_RECEIPT"] {
            let facts: [String: Any] = ["framework": "Apple.Translation", "languagePair": ["en","zh-Hans"],
                "model": available == .installed ? "installed" : available == .supported ? "supported, not installed" : "unsupported",
                "sourceSHA256": req.hash, "resultSHA256": saved.map { LocalToolStage.digest(Data($0.translation.utf8)) } as Any? ?? NSNull(),
                "wordReopened": saved != nil, "privateTextLogged": false, "installedServicesEntryAndPanel": "NOT_RUN"]
            try JSONSerialization.data(withJSONObject: facts, options:[.sortedKeys,.prettyPrinted]).write(to: URL(fileURLWithPath: output), options:.atomic)
        }
        service.detach()
    }
    #endif
}
