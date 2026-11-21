import Foundation
import Testing
@testable import NearpaneUI

@MainActor struct R4ToolTests {
    @Test func groupingNeedsAnExplicitActionAndExpiresWithTheExactWindow() {
        let group = ExplicitWindowGroups(), space = UUID(), other = UUID()
        let a = DesktopWindowKey(pid: 4, birth: 50, number: 30), b = DesktopWindowKey(pid: 4, birth: 50, number: 31)
        let c = DesktopWindowKey(pid: 7, birth: 70, number: 32)
        let lifetimes = [a: UUID(), b: UUID(), c: UUID()]
        #expect(group.visible(space: space, members: [a,b,c]).isEmpty)
        group.join(a, b, space: space, lifetimes: lifetimes)
        group.join(c, b, space: space, lifetimes: lifetimes)
        #expect(group.records.count == 1 && group.visible(space: space, members: [a,b,c]).count == 3)
        #expect(group.visible(space: other, members: [a,b,c]).isEmpty && group.visible(space: space, members: [a,b]).isEmpty)
        group.reconcile(lifetimes: lifetimes) { key, _ in key == c }
        #expect(group.visible(space: space, members: [a,b]).count == 2)
        group.reconcile(lifetimes: [a: UUID(), b: lifetimes[b]!]) { _, _ in false }
        #expect(group.records.isEmpty)
    }

    @Test func calculationAndNotebookSurviveReopenWithIndependentMemoAndVocabulary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let note = SidebarNotebook(directory: root)
        #expect(note.edit { c in
            c.memo = "计划"; c.calculation = "(7 − 2) × 3 ÷ 2"; c.tasks.append(.init(title: "核对", done: true))
            c.words.append(.init(source: "rail", translation: "栏杆", language: "zh-Hans"))
        })
        let saved = SidebarNotebook(directory: root).contents
        #expect(saved.memo == "计划" && saved.calculation == "(7 − 2) × 3 ÷ 2")
        #expect(NoteArithmetic.result(saved.calculation) == "7.5")
        #expect(saved.tasks.first?.done == true && saved.words.first?.source == "rail")
        for invalid in ["1/0", "process()", "1.0.2", "4+", "(1+2"] { #expect(NoteArithmetic.result(invalid) == nil) }
    }
}
