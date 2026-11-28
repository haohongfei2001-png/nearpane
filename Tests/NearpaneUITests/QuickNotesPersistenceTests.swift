import Foundation
import Testing
@testable import NearpaneUI

@MainActor struct QuickNotesPersistenceTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("nearpane-quick-notes-" + UUID().uuidString)
    }

    @Test func immediateWritesKeepMultipleNotesAndRestoreTheExactActiveDraft() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let notebook = SidebarNotebook(directory: root)
        #expect(notebook.readable && notebook.records.isEmpty && notebook.activeRecord == nil)
        let first = try #require(notebook.beginNote())
        #expect(notebook.beginNote() == first)
        let text = "这个想法先记下来。\n第二行：中文、emoji 🏔️，以及保留的空格  "
        #expect(notebook.updateActiveBody(text))
        // A separate instance reads disk immediately, without a save/close/flush callback.
        #expect(SidebarNotebook(directory: root).record(first)?.body == text)
        let second = try #require(notebook.beginNote())
        #expect(second != first)
        #expect(notebook.updateActiveBody("第二条，还在输入"))
        let third = try #require(notebook.beginNote())
        #expect(notebook.updateActiveBody("第三条"))
        let reopened = SidebarNotebook(directory: root)
        #expect(Set(reopened.records.map(\.id)) == [first, second, third])
        #expect(reopened.activeRecordID == third && reopened.activeRecord?.body == "第三条")
        #expect(reopened.record(first)?.body == text)
        #expect(!reopened.hasUnsavedChanges)
    }

    @Test func conversionPreservesIdentityContentCreationAndOtherRecords() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let notebook = SidebarNotebook(directory: root)
        let id = try #require(notebook.beginNote())
        let text = "整理 B→Kℓ⁺ℓ⁻ 的数值结果\n保留换行与公式"
        #expect(notebook.updateRecord(id, body: text))
        let creation = try #require(notebook.record(id)?.createdAt)
        #expect(notebook.convertRecord(id, to: .task))
        #expect(notebook.activeRecordID == nil && notebook.unfinishedTasks.map(\.id) == [id])
        #expect(notebook.setCompleted(id, completed: true))
        let completedAt = try #require(notebook.record(id)?.completedAt)
        #expect(notebook.setCompleted(id, completed: true))
        #expect(notebook.record(id)?.completedAt == completedAt)
        let other = try #require(notebook.beginNote())
        #expect(notebook.updateActiveBody("当前另一条想法"))
        #expect(notebook.convertRecord(id, to: .note))
        #expect(notebook.convertRecord(id, to: .note))
        let reopened = SidebarNotebook(directory: root)
        let result = try #require(reopened.record(id))
        #expect(result.body == text && result.createdAt == creation && result.kind == .note)
        #expect(!result.isCompleted && result.completedAt == nil)
        #expect(reopened.activeRecordID == id && reopened.records.count == 2)
        #expect(reopened.record(other)?.body == "当前另一条想法")
    }

    @Test func completionUncompletionAndLibrarySearchUseTheSameDurableRecords() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let notebook = SidebarNotebook(directory: root)
        let todo = try #require(notebook.createTask(body: "寄出资料"))
        let other = try #require(notebook.createTask(body: "阅读 Café 的设计笔记"))
        #expect(notebook.setCompleted(todo, completed: true))
        #expect(notebook.unfinishedTasks.map(\.id) == [other])
        #expect(notebook.records(matching: "资料", filter: .completed).map(\.id) == [todo])
        #expect(notebook.records(matching: " CAFE ", filter: .unfinished).map(\.id) == [other])
        let reopened = SidebarNotebook(directory: root)
        #expect(reopened.setCompleted(todo, completed: false))
        #expect(reopened.record(todo)?.completedAt == nil)
        #expect(Set(SidebarNotebook(directory: root).unfinishedTasks.map(\.id)) == [todo, other])
    }

    @Test func migrationPreservesLegacyBytesTasksVocabularyAndCalculationExactlyOnce() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pending = UUID(), completed = UUID(), word = UUID()
        let legacy: [String: Any] = [
            "memo": "旧便签的完整正文\n另一行  ", "calculation": "(7 − 2) × 3 ÷ 2",
            "tasks": [["id": pending.uuidString, "title": "未完成任务", "done": false],
                      ["id": completed.uuidString, "title": "已完成任务", "done": true]],
            "words": [["id": word.uuidString, "source": "rail", "translation": "栏杆", "language": "zh-Hans"]]
        ]
        let bytes = try JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys, .prettyPrinted])
        let primary = root.appendingPathComponent("sidebar-notebook.json")
        try bytes.write(to: primary)
        let migrated = SidebarNotebook(directory: root)
        let memo = try #require(migrated.activeRecord)
        #expect(migrated.records.count == 3 && memo.body == legacy["memo"] as? String)
        #expect(migrated.record(pending)?.body == "未完成任务" && migrated.record(pending)?.isCompleted == false)
        #expect(migrated.record(completed)?.isCompleted == true && migrated.record(completed)?.completedAt != nil)
        #expect(migrated.contents.calculation == legacy["calculation"] as? String)
        #expect(migrated.contents.words.first?.id == word && migrated.contents.words.first?.translation == "栏杆")
        #expect(try Data(contentsOf: root.appendingPathComponent("sidebar-notebook.v1-backup.json")) == bytes)
        let convertedBytes = try Data(contentsOf: primary)
        let reopened = SidebarNotebook(directory: root)
        #expect(reopened.records == migrated.records && reopened.activeRecordID == memo.id)
        #expect(try Data(contentsOf: primary) == convertedBytes)
        #expect(reopened.contents.memo == memo.body && reopened.contents.tasks.count == 2)
    }

    @Test func unchangedInputAndRepeatedActionsDoNotRewriteOrReviseDates() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let notebook = SidebarNotebook(directory: root)
        let id = try #require(notebook.createTask(body: "保持原文"))
        let before = try #require(notebook.record(id))
        let primary = root.appendingPathComponent("sidebar-notebook.json")
        let bytes = try Data(contentsOf: primary)
        let changedAt = try FileManager.default.attributesOfItem(atPath: primary.path)[.modificationDate] as? Date
        #expect(notebook.updateRecord(id, body: before.body))
        #expect(notebook.setCompleted(id, completed: false))
        #expect(notebook.convertRecord(id, to: .task))
        #expect(notebook.deleteRecord(UUID()))
        #expect(notebook.record(id) == before)
        #expect(try Data(contentsOf: primary) == bytes)
        #expect(try FileManager.default.attributesOfItem(atPath: primary.path)[.modificationDate] as? Date == changedAt)
    }

    @Test func emptyTaskDraftPersistsBeforeReturnAndBlankNoteDoesNotMultiply() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let notebook = SidebarNotebook(directory: root)
        let task = try #require(notebook.createTask(body: ""))
        #expect(notebook.createTask(body: "") == task)
        #expect(SidebarNotebook(directory: root).createTask(body: "") == task)
        #expect(notebook.updateRecord(task, body: "尚未按回车"))
        #expect(SidebarNotebook(directory: root).record(task)?.body == "尚未按回车")
        let draft = try #require(notebook.beginNote())
        #expect(notebook.beginNote() == draft)
        #expect(notebook.records(matching: "").map(\.id) == [task])
        #expect(notebook.endNote())
        #expect(notebook.record(draft) == nil && notebook.activeRecordID == nil)
        #expect(SidebarNotebook(directory: root).records.map(\.id) == [task])
    }

    @Test func endingAndFocusingNotesRetainHistoryWithoutClobberingTheActiveNote() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let notebook = SidebarNotebook(directory: root)
        let original = try #require(notebook.beginNote())
        #expect(notebook.updateActiveBody("留在历史中"))
        #expect(notebook.endNote())
        #expect(notebook.activeRecordID == nil && notebook.record(original)?.body == "留在历史中")
        let blank = try #require(notebook.beginNote())
        #expect(notebook.focusRecord(original))
        #expect(notebook.record(blank) == nil)
        let reopened = SidebarNotebook(directory: root)
        #expect(reopened.activeRecordID == original && reopened.records.count == 1)
        #expect(reopened.deleteRecord(original))
        #expect(SidebarNotebook(directory: root).activeRecordID == nil)
    }

    @Test func aFailedWriteKeepsTheTextAndRetryCommitsWithoutDuplicating() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let notebook = SidebarNotebook(directory: root)
        let id = try #require(notebook.beginNote())
        #expect(notebook.updateActiveBody("原来已保存的文字"))
        let primary = root.appendingPathComponent("sidebar-notebook.json")
        try FileManager.default.removeItem(at: primary)
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: false)
        #expect(!notebook.updateActiveBody("磁盘故障期间的新文字，也不能丢"))
        #expect(notebook.activeRecord?.body == "磁盘故障期间的新文字，也不能丢")
        #expect(notebook.hasUnsavedChanges && notebook.issue != nil)
        try FileManager.default.removeItem(at: primary)
        #expect(notebook.retrySave())
        let reopened = SidebarNotebook(directory: root)
        #expect(!notebook.hasUnsavedChanges && notebook.issue == nil)
        #expect(reopened.records.count == 1 && reopened.activeRecordID == id)
        #expect(reopened.activeRecord?.body == "磁盘故障期间的新文字，也不能丢")
    }

    @Test func corruptPrimaryStaysUntouchedUntilRecoveryAndKeepsItsOriginalBytes() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let notebook = SidebarNotebook(directory: root)
        let id = try #require(notebook.createTask(body: "恢复最后一份完整记录"))
        #expect(notebook.setCompleted(id, completed: true))
        let corrupt = Data("{\"schemaVersion\":2,\"records\":[".utf8)
        let primary = root.appendingPathComponent("sidebar-notebook.json")
        try corrupt.write(to: primary, options: .atomic)
        let reopened = SidebarNotebook(directory: root)
        #expect(!reopened.readable && reopened.recoveryAvailable)
        #expect(!reopened.edit { $0.memo = "不能覆盖原文件" })
        #expect(try Data(contentsOf: primary) == corrupt)
        #expect(reopened.recoverLastSavedCopy())
        #expect(reopened.readable && reopened.record(id)?.body == "恢复最后一份完整记录")
        #expect(reopened.record(id)?.isCompleted == true)
        let preserved = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("sidebar-notebook.unreadable-") }
        #expect(preserved.count == 1)
        let preservedFile = try #require(preserved.first)
        #expect(try Data(contentsOf: preservedFile) == corrupt)
        #expect(SidebarNotebook(directory: root).record(id) == reopened.record(id))
    }

    @Test func newerSchemaIsReadOnlyEvenWhenAnOlderRecoveryCopyExists() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let notebook = SidebarNotebook(directory: root)
        _ = notebook.createTask(body: "旧数据")
        let future = Data(#"{"schemaVersion":99,"records":[{"future":"do not downgrade"}]}"#.utf8)
        let primary = root.appendingPathComponent("sidebar-notebook.json")
        try future.write(to: primary, options: .atomic)
        let reopened = SidebarNotebook(directory: root)
        #expect(!reopened.readable && !reopened.recoveryAvailable)
        #expect(reopened.issue?.contains("更新版本") == true)
        #expect(reopened.beginNote() == nil && !reopened.recoverLastSavedCopy())
        #expect(try Data(contentsOf: primary) == future)
    }

    @Test func legacyCompatibilityEditsAndVocabularyDoNotCreateASecondRecordStore() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let notebook = SidebarNotebook(directory: root)
        #expect(notebook.edit {
            $0.memo = "兼容原便签入口"
            $0.tasks.append(.init(title: "兼容旧待办", done: true))
            $0.calculation = "2 + 3"
            $0.words.append(.init(source: "idea", translation: "想法", language: "zh-Hans"))
        })
        let reopened = SidebarNotebook(directory: root)
        #expect(reopened.records.count == 2 && reopened.contents.tasks.first?.done == true)
        let data = try Data(contentsOf: root.appendingPathComponent("sidebar-notebook.json"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 2)
        #expect(object["memo"] == nil && object["tasks"] == nil)
        #expect(reopened.contents.memo == "兼容原便签入口" && reopened.contents.words.first?.source == "idea")
    }

    @Test func recoveryMirrorFailureDoesNotMisreportACommittedPrimaryAsUnsaved() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let notebook = SidebarNotebook(directory: root)
        let id = try #require(notebook.createTask(body: "上一份正文"))
        let recovery = root.appendingPathComponent("sidebar-notebook.recovery.json")
        try FileManager.default.removeItem(at: recovery)
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: false)
        #expect(notebook.updateRecord(id, body: "主文件已经保存的正文"))
        #expect(!notebook.hasUnsavedChanges && notebook.issue?.contains("恢复副本") == true)
        #expect(SidebarNotebook(directory: root).record(id)?.body == "主文件已经保存的正文")
        try FileManager.default.removeItem(at: recovery)
        #expect(notebook.retrySave() && notebook.issue == nil)
    }

    @Test func missingPrimaryNeverStartsAnEmptyNotebookOverExistingRecoveryData() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let notebook = SidebarNotebook(directory: root)
        let id = try #require(notebook.createTask(body: "仍在恢复副本里的资料"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("sidebar-notebook.json"))
        let reopened = SidebarNotebook(directory: root)
        #expect(!reopened.readable && reopened.recoveryAvailable && reopened.beginNote() == nil)
        #expect(reopened.recoverLastSavedCopy())
        #expect(reopened.record(id)?.body == "仍在恢复副本里的资料")
    }
}
