import Foundation
import Testing
@testable import NearpaneUI

@MainActor struct QuickNotesShutdownTests {
    @Test func aHealthyNotebookDoesNotWriteOrBlockNormalShutdown() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-shutdown-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let modules = EmbeddedModules(support: root, testSession: root)
        #expect(modules.prepareNotebookShutdown())
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("sidebar-notebook.json").path))
        await modules.finishStopping()
    }

    @Test func failedDraftBlocksReleaseAndUpdateUntilAnAutomaticRetryCanPersistIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-shutdown-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let modules = EmbeddedModules(support: root, testSession: root)
        let id = try #require(modules.notebook.beginNote())
        #expect(modules.notebook.updateRecord(id, body: "原来已经保存的文字"))
        let primary = root.appendingPathComponent("sidebar-notebook.json")
        try FileManager.default.removeItem(at: primary)
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: false)
        #expect(!modules.notebook.updateRecord(id, body: "必须保留的最新文字"))
        #expect(!modules.prepareNotebookShutdown())
        let updateBlock = await modules.updateRelaunchBlock()
        #expect(updateBlock?.contains("随手记") == true)
        #expect(modules.notebook.record(id)?.body == "必须保留的最新文字")
        try FileManager.default.removeItem(at: primary)
        #expect(modules.prepareNotebookShutdown())
        #expect(!modules.notebook.hasUnsavedChanges)
        #expect(SidebarNotebook(directory: root).record(id)?.body == "必须保留的最新文字")
        await modules.finishStopping()
    }
}
