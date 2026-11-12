import AppKit
import SwiftUI
import Testing
@testable import NearpaneVoice
import SaytileKit
import SaytileVoiceUI

@MainActor
private struct EmbeddedEditorWindow {
    let panel: NSPanel
    let text: CompactTranscriptTextView
    let board: NSPasteboard

    init(_ module: VoiceModule) throws {
        _ = NSApplication.shared
        board = NSPasteboard.withUniqueName()
        let content = NSHostingView(rootView: VoiceSurface(module, pasteboard: board))
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 248, height: 144),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = content
        content.layoutSubtreeIfNeeded()
        func editor(in view: NSView) -> CompactTranscriptTextView? {
            if let text = view as? CompactTranscriptTextView { return text }
            for child in view.subviews {
                if let text = editor(in: child) { return text }
            }
            return nil
        }
        text = try #require(editor(in: content))
        #expect(text.isEditable && text.isSelectable && panel.makeFirstResponder(text))
        try #require(text.commandPasteboard === board)
    }

    func command(_ key: String, flags: NSEvent.ModifierFlags = .command) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
            characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0))
        #expect(text.performKeyEquivalent(with: event))
    }

    func visibleRowText() throws -> [String] {
        let scroll = try #require(text.enclosingScrollView as? CompactTranscriptScrollView<VoiceHistoryEntry>)
        let rendered = text.string as NSString
        return scroll.rendered.spans.map { rendered.substring(with: $0.range) }
    }

    func close() {
        board.releaseGlobally()
        panel.close()
    }
}

extension VoiceTests {
    @Test func embeddedNativeEditorPersistsTypingCopyPasteAndDeletion() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SaytileStore(directory: directory)
        let module = VoiceModule(openStore: { store }, makeInput: { _, callback in
            Issue.record("Typing must not start the microphone")
            return ScriptedInput(callback)
        })
        try module.start()
        await module.waitForTransition()

        let window = try EmbeddedEditorWindow(module)
        defer { window.close() }
        let text = window.text
        let insertion = NSRange(location: NSNotFound, length: 0)
        text.insertText("甲🌿乙", replacementRange: insertion)
        let id = try #require(module.rows.first?.id)
        #expect(text.string == "甲🌿乙")
        text.setSelectedRange((text.string as NSString).range(of: "🌿"))
        #expect(text.selectedRange() == NSRange(location: 1, length: 2))
        try window.command("c")
        #expect(window.board.string(forType: .string) == "🌿")
        try window.command("x")
        #expect(module.transcript == "甲乙")
        try window.command("v")
        text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
        text.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: insertion)
        #expect(text.hasMarkedText() && module.transcript == "甲🌿乙")
        text.insertText("中", replacementRange: insertion)
        let persisted = try #require(try await store.recording(id: id))
        #expect(persisted.text == "甲🌿乙中" && persisted.audioState == .deleted && !persisted.isRecording)
        #expect(window.board.string(forType: .string) == "🌿")
        #expect(!(try await store.revisions(recordingID: id)).contains { $0.text.contains("zhong") })
        try window.command("a")
        text.deleteBackward(nil)
        #expect(try await store.recording(id: id)?.text == "")
        #expect(try await store.revisions(recordingID: id).contains { $0.text == persisted.text })
        #expect(!window.panel.isVisible && !window.panel.isKeyWindow && module.capture == .paused)
        module.stop()
        await module.waitForTransition()

        let restored = VoiceModule(directory: directory)
        try restored.start()
        await restored.waitForTransition()
        #expect(restored.rows.count == 1 && restored.rows.first?.id == id && restored.transcript.isEmpty)
        restored.stop()
        await restored.waitForTransition()
    }

    @Test func separateDaysAndSpeechPausesPresentOneEditableSurface() async throws {
        let path = directory()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try SaytileStore(directory: path)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for (offset, text) in [(0.0, "先说中文。"), (86_400, "Saytile"), (86_410, "works"), (86_420, "\n保留手动换行")] {
            let row = try await store.createRecording(createdAt: start.addingTimeInterval(offset))
            _ = try await store.saveEdit(recordingID: row.id, text: text)
        }
        let module = VoiceModule(openStore: { store }, makeInput: { _, callback in ScriptedInput(callback) })
        try module.start()
        await module.waitForTransition()
        let window = try EmbeddedEditorWindow(module)
        defer { window.close() }
        let text = "先说中文。Saytile works\n保留手动换行"
        #expect(window.text.string == text && module.transcript == text)
        let selected = (text as NSString).range(of: "中文。Saytile")
        window.text.setSelectedRange(selected)
        #expect(window.text.string == text && window.text.selectedRange() == selected)
        module.copyLatestGroup(snapshot: [:], to: window.board)
        #expect(window.board.string(forType: .string) == "Saytile works\n保留手动换行")
        module.stop()
        await module.waitForTransition()
    }

    @Test func crossRecordingEditRejectsStaleHumanRevisionWithoutPartialWrites() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SaytileStore(directory: directory)
        let first = try await store.createRecording()
        let ticket = try await store.beginRecognition(recordingID: first.id)
        _ = try await store.applyRecognition(ticket: ticket, text: "声音甲", isFinal: false)
        let second = try await store.createRecording()
        _ = try await store.saveEdit(recordingID: second.id, text: "声音乙")
        let module = VoiceModule(openStore: { store }, makeInput: { _, callback in ScriptedInput(callback) })
        try module.start()
        await module.waitForTransition()
        let window = try EmbeddedEditorWindow(module)
        defer { window.close() }
        try window.command("a")
        window.text.insertText("手动合并", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(module.transcript == "手动合并")
        try window.command("z")
        #expect(try window.visibleRowText() == ["声音甲", "声音乙"])
        #expect(try await store.recording(id: first.id)?.text == "声音甲")
        #expect(try await store.recording(id: second.id)?.text == "声音乙")
        try window.command("z", flags: [.command, .shift])
        #expect(try window.visibleRowText() == ["手动合并"])
        #expect(try await store.recording(id: second.id)?.text == "")
        try window.command("z")
        let cross = [VoicePanelEdit(id: first.id, before: "声音甲", after: "手动合并"),
                     VoicePanelEdit(id: second.id, before: "声音乙", after: "")]
        _ = try await store.saveEdit(recordingID: second.id, text: "另一处刚保存的修改")
        #expect(throws: StoreError.self) { try module.applyPanelEdits(cross) }
        #expect(try await store.recording(id: first.id)?.text == "声音甲")
        #expect(try await store.recording(id: second.id)?.text == "另一处刚保存的修改")
        try module.applyPanelEdits([cross[0]])
        _ = try await store.applyRecognition(ticket: ticket, text: "原音稍后完成", isFinal: true)
        await module.refresh()
        #expect(module.rows.first { $0.id == first.id }?.text == "手动合并")
        #expect(try await store.revisions(recordingID: first.id).contains { $0.text == "原音稍后完成" })
        #expect(try await store.recording(id: first.id)?.audioState == .available)
        module.stop()
        await module.waitForTransition()
    }
}
