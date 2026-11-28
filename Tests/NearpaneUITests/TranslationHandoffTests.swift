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

    @Test func wordbookSearchReadsBothColumnsAfterRestartAndPreservesTheProfile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let note = SidebarNotebook(directory: root)
        #expect(note.edit { $0.words.append(.init(source: "旧格式", translation: "Legacy Entry", language: "en")) })
        let request = try TranslationRequest("Café", generation: UUID())
        let coffee = try note.commit(request, answer: "咖啡馆", from: "fr", to: "zh-Hans", provider: "fixture")
        let reopened = SidebarNotebook(directory: root)
        let file = root.appendingPathComponent("sidebar-notebook.json")
        let bytes = try Data(contentsOf: file)
        #expect(reopened.words(matching: "  CAFE ").map(\.id) == [coffee.id])
        #expect(reopened.words(matching: "啡馆").map(\.id) == [coffee.id])
        #expect(reopened.words(matching: "legacy").map(\.source) == ["旧格式"])
        #expect(reopened.words(matching: "not present").isEmpty)
        #expect(reopened.words(matching: "\n ") == reopened.contents.words)
        #expect(reopened.savedTranslation(for: " Cafe\u{301} ", from: "fr", to: "zh-Hans") == "咖啡馆")
        #expect(reopened.savedTranslation(for: "旧格式", from: "zh", to: "en") == nil)
        #expect(SidebarNotebook(directory: root.appendingPathComponent("other")).words(matching: "").isEmpty)
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func aSavedAnswerRequiresExactTextDirectionAndAgreement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let note = SidebarNotebook(directory: root)
        func store(_ source: String, _ answer: String, _ version: String) throws {
            _ = try note.commit(TranslationRequest(source, generation: nil), answer: answer,
                                from: "en", to: "zh-Hans", provider: version)
        }
        try store("US", "美国", "fixture/1")
        try store("US", "美国", "fixture/2")
        #expect(note.savedTranslation(for: "US", from: "en", to: "zh-Hans") == "美国")
        #expect(note.savedTranslation(for: "us", from: "en", to: "zh-Hans") == nil)
        #expect(note.savedTranslation(for: "U", from: "en", to: "zh-Hans") == nil)
        #expect(note.savedTranslation(for: "US", from: "zh-Hans", to: "en") == nil)
        try store("US", "美利坚合众国", "fixture/3")
        #expect(note.savedTranslation(for: "US", from: "en", to: "zh-Hans") == nil)
        let file = root.appendingPathComponent("sidebar-notebook.json")
        let damaged = Data("fixture: incomplete document".utf8)
        try damaged.write(to: file, options: .atomic)
        let unreadable = SidebarNotebook(directory: root)
        #expect(!unreadable.readable && unreadable.issue != nil)
        #expect(unreadable.savedTranslation(for: "US", from: "en", to: "zh-Hans") == nil)
        #expect(try Data(contentsOf: file) == damaged)
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
        var savedLookup: UUID?
        if available != .installed {
            let seed = try TranslationRequest(req.source, generation: generation)
            let original = try note.commit(seed, answer: "蓝色自行车", from: "en", to: "zh-Hans", provider: "fixture")
            let lookup = try TranslationRequest(req.source, generation: generation)
            try inbox.append(lookup)
            let reopened = SidebarNotebook(directory: root.appendingPathComponent("notebook"))
            service.bind(notebook: reopened, generation: generation)
            await service.waitForRequests()
            #expect(try inbox.pending(for: generation).isEmpty)
            #expect(try reopened.diskWord(for: lookup.id) == nil)
            #expect(SidebarNotebook(directory: root.appendingPathComponent("notebook")).contents.words == [original])
            savedLookup = lookup.id
        }
        if let output = ProcessInfo.processInfo.environment["NEARPANE_P4_TRANSLATION_RECEIPT"] {
            let facts: [String: Any] = ["framework": "Apple.Translation", "languagePair": ["en","zh-Hans"],
                "model": available == .installed ? "installed" : available == .supported ? "supported, not installed" : "unsupported",
                "sourceSHA256": req.hash, "resultSHA256": saved.map { LocalToolStage.digest(Data($0.translation.utf8)) } as Any? ?? NSNull(),
                "wordReopened": saved != nil, "privateTextLogged": false, "installedServicesEntryAndPanel": "NOT_RUN",
                "savedLookupRequest": savedLookup?.uuidString as Any? ?? NSNull()]
            try JSONSerialization.data(withJSONObject: facts, options:[.sortedKeys,.prettyPrinted]).write(to: URL(fileURLWithPath: output), options:.atomic)
        }
        service.detach()
    }
    #endif
}
