import AppKit
import SwiftUI
import Testing
@testable import NearpaneVoice

@MainActor @Suite(.serialized)
struct TranscriptTypographyTests {
    private let text = "第一行合成文字\n第二行合成文字\n第三行合成文字"

    private func textView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        return view.subviews.lazy.compactMap { textView(in: $0) }.first
    }

    private func hosted<V: View>(_ content: V) throws -> (NSPanel, NSTextView) {
        _ = NSApplication.shared
        let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 280, height: 240),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: content)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let native = try #require(textView(in: host))
        #expect(!window.isVisible && !window.isKeyWindow)
        return (window, native)
    }

    private func measuredHeight(_ view: NSTextView) throws -> Double {
        let container = try #require(view.textContainer)
        container.containerSize = CGSize(width: 260, height: 1000)
        let layout = try #require(view.layoutManager)
        layout.ensureLayout(for: container)
        return layout.usedRect(for: container).height
    }

    @Test func explicitSpacingChangesLinesWithinOneRecordingAndResetsToFactory() throws {
        let (window, native) = try hosted(TranscriptLine(text: text, fontSize: 13, edit: { _ in }))
        defer { window.close() }
        let host = try #require(window.contentView as? NSHostingView<TranscriptLine>)
        let baseline = try measuredHeight(native)
        let selection = NSRange(location: 1, length: 3)
        native.setSelectedRange(selection)

        host.rootView = TranscriptLine(text: text, fontSize: 13, lineSpacing: 7, edit: { _ in })
        host.layoutSubtreeIfNeeded()
        #expect(native.defaultParagraphStyle?.lineSpacing == 7)
        #expect(try measuredHeight(native) >= baseline + 14)
        #expect(native.selectedRange() == selection)
        #expect(native.string == text)

        host.rootView = TranscriptLine(text: text, fontSize: 13, edit: { _ in })
        host.layoutSubtreeIfNeeded()
        #expect(native.defaultParagraphStyle == nil)
        #expect(try measuredHeight(native) == baseline)
        #expect(native.selectedRange() == selection)
    }

    @Test func nativeEditorAndReadOnlyTranscriptUseTheSameExplicitSpacing() throws {
        let (readerWindow, reader) = try hosted(TranscriptLine(text: text, fontSize: 13, lineSpacing: 6, edit: { _ in }))
        defer { readerWindow.close() }
        let (editorWindow, editor) = try hosted(TranscriptEditor(text: .constant(text), fontSize: 13, lineSpacing: 6))
        defer { editorWindow.close() }
        let readerStyle = try #require(reader.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let editorStyle = try #require(editor.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(readerStyle.lineSpacing == 6)
        #expect(editorStyle.lineSpacing == readerStyle.lineSpacing)
        #expect(reader.string == text && editor.string == text)
        #expect(!reader.isEditable && editor.isEditable)

        let (factoryWindow, factoryEditor) = try hosted(TranscriptEditor(text: .constant(text), fontSize: 13, lineSpacing: nil))
        defer { factoryWindow.close() }
        let (originalWindow, originalEditor) = try hosted(TextEditor(text: .constant(text)).font(.system(size: 13)))
        defer { originalWindow.close() }
        #expect(try measuredHeight(factoryEditor) == measuredHeight(originalEditor))
        #expect(factoryEditor.string == originalEditor.string)
    }
}
