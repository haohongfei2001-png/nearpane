import CoreServices
import CryptoKit
import Foundation
import NearpaneCore
import Testing
@testable import NearpaneUI

struct SeededWordbookRecoveryTests {
    @MainActor @Test func productionNotebookWritesAndReopensTheDisclosedExistingEntry() throws {
        let term = "bicycle", answer = "自行车"
        if let path = ProcessInfo.processInfo.environment["NEARPANE_WORD_SEED_KIT"] {
            // This export is confined to a new, current-user, private temporary kit.
            let kit = URL(fileURLWithPath: path, isDirectory: true)
            var info = stat()
            let physical = try #require(realpath(path, nil))
            defer { free(physical) }
            try #require(String(cString: physical) == path && kit.deletingLastPathComponent().path == "/private/tmp"
                         && kit.lastPathComponent.hasPrefix("nearpane-p4-wordbook.")
                         && lstat(path, &info) == 0 && info.st_uid == getuid()
                         && info.st_mode & S_IFMT == S_IFDIR && info.st_mode & 0o077 == 0)
            let definition = try #require(DCSCopyTextDefinition(nil, term as CFString, CFRangeMake(0, term.utf16.count))?
                .takeRetainedValue() as String?)
            try #require(definition.contains(answer))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nearpane-word-seed-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let req = try TranslationRequest(term, generation: UUID())
        let provider = "seeded existing entry / Dictionary Services"
        let word = try SidebarNotebook(directory: root).commit(req, answer: answer, from: "en", to: "zh-Hans", provider: provider)
        let fresh = SidebarNotebook(directory: root)
        #expect(fresh.contents.words == [word] && fresh.contents.tasks.isEmpty && fresh.contents.memo.isEmpty && fresh.contents.calculation.isEmpty)
        #expect(try fresh.diskWord(for: req.id) == word)
        #expect(word.sourceSHA256 == req.hash && word.requestID == req.id && word.providerVersion == provider)
        let data = try Data(contentsOf: root.appendingPathComponent("sidebar-notebook.json"))
        if let path = ProcessInfo.processInfo.environment["NEARPANE_WORD_SEED_KIT"] {
            let kit = URL(fileURLWithPath: path)
            let receipt: [String: Any] = ["kind":"seeded existing entry","wordID":word.id.uuidString,"requestID":req.id.uuidString,
                "source":term,"answer":answer,"providerVersion":provider,"sourceSHA256":req.hash,
                "answerSHA256":LocalToolStage.digest(Data(answer.utf8)),"fileSHA256":LocalToolStage.digest(data),
                "serialization":"SidebarNotebook.commit","serviceRequests":0,"translationSessionRequests":0]
            try data.write(to: kit.appendingPathComponent("seed-notebook.json"), options: .withoutOverwriting)
            try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
                .write(to: kit.appendingPathComponent("seed.json"), options: .withoutOverwriting)
        }
    }
}
