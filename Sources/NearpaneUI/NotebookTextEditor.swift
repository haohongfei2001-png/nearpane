import AppKit
import SwiftUI

/// The sidebar and library use the same native plain-text editor. Updating a
/// different view of a record never resets the active IME composition or caret.
struct NotebookTextEditor: NSViewRepresentable {
    @Binding var text: String
    let identifier: String
    var fontSize: CGFloat = 14
    var focusRequest: Int = 0
    var onFocusChanged: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.horizontalScrollElasticity = .none
        let editor = NSTextView(frame: .zero)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.font = .systemFont(ofSize: fontSize)
        editor.textContainerInset = NSSize(width: 0, height: 3)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]
        editor.setAccessibilityIdentifier(identifier)
        editor.setAccessibilityLabel(identifier == "notebook-editor" ? "记录正文" : "随手记录正文")
        editor.string = text
        editor.delegate = context.coordinator
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        editor.setAccessibilityIdentifier(identifier)
        editor.font = .systemFont(ofSize: fontSize)
        if editor.string != text && !editor.hasMarkedText() {
            let selection = editor.selectedRange()
            editor.string = text
            let count = (text as NSString).length
            editor.setSelectedRange(NSRange(location: min(selection.location, count),
                length: min(selection.length, max(0, count - min(selection.location, count)))))
            // A different record must not inherit the old record's undo actions.
            if context.coordinator.recordIdentifier != identifier { editor.undoManager?.removeAllActions() }
        }
        context.coordinator.recordIdentifier = identifier
        if focusRequest != context.coordinator.lastFocusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            if focusRequest > 0 {
                DispatchQueue.main.async { [weak editor] in
                    guard let editor, let window = editor.window else { return }
                    window.makeFirstResponder(editor)
                    editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
                }
            }
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        // Finish only this editor's live composition. Unconditionally writing a
        // dormant view would overwrite an edit made from the other surface.
        if editor.hasMarkedText() {
            let composed = editor.string
            editor.unmarkText()
            coordinator.parent.text = composed
        }
        editor.delegate = nil
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NotebookTextEditor
        var lastFocusRequest = 0
        var recordIdentifier = ""
        init(_ parent: NotebookTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
        func textDidBeginEditing(_ notification: Notification) { parent.onFocusChanged(true) }
        func textDidEndEditing(_ notification: Notification) { parent.onFocusChanged(false) }
    }
}
