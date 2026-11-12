import AppKit
import ApplicationServices
import Testing
@testable import NearpaneVoice
@testable import SaytileKit

/// The real coordinator and dispatch journal run, but no AppKit window, system AX
/// element, pasteboard, microphone or key event is involved in these calls.
@MainActor private final class SelectedField: InputAccess {
    var hasPermission = true
    var target = InputTargetSnapshot(processID: 4377, applicationID: "test.synthetic", applicationName: "合成草稿",
        windowID: UUID(), elementID: UUID(), pageIdentity: nil, selectionLocation: 0, selectionLength: 0,
        isWeb: false, isEditable: true, isSensitive: false, canSetSelectedText: true)
    var evidence = true
    var readCount = 0
    var sent = [String]()
    var observed: (@MainActor (InputTargetChange) -> Void)?
    func snapshot() throws -> InputTargetSnapshot { readCount += 1; return target }
    func observe(_ expected: InputTargetSnapshot, onChange: @escaping @MainActor (InputTargetChange) -> Void) -> InputObservationSupport {
        observed = onChange
        return .init(focus: true, content: true, page: true)
    }
    func stopObserving() { observed = nil }
    func dispatch(_ text: String, to expected: InputTargetSnapshot) throws -> Bool {
        guard expected == target else { return false }
        sent.append(text)
        target.selectionLocation += text.utf16.count
        return true
    }
    func verify(_ text: String, at before: InputTargetSnapshot) -> InputTargetSnapshot? { evidence ? target : nil }
    func matchesText(_ text: String, utf16Start: Int, at expected: InputTargetSnapshot) -> Bool? {
        evidence && sent.contains(text)
    }
}

@MainActor struct ManualVoiceInsertionTests {
    @Test(arguments: ["application", "terminated", "window", "field", "unowned", "webArea", "documentURL", "stable"])
    func foregroundMismatchStopsBeforeUnrelatedSemanticReads(change: String) throws {
        // These opaque handles never receive AX requests; both ownership and document
        // metadata readers are injected, as is the foreground provider.
        let app = NSRunningApplication.current
        let original = AXUIElementCreateApplication(31871)
        let other = AXUIElementCreateApplication(31872)
        var front: pid_t? = app.processIdentifier
        var selected = AXInputSelection(application: app, root: original, window: original, element: original)
        var area = original
        var address = "test://one"
        var live = true, owned = true
        var focusReads = 0, metadataReads = 0, semanticsReads = 0
        let scope = GestureFieldSelection(frontPID: { front }, focus: { focusReads += 1; return selected },
            isLive: { _ in live }, isOwned: { _ in owned }, document: { _ in
                metadataReads += 1
                return .init(area: area, address: address)
            })
        func read() throws {
            _ = try scope.selected()
            semanticsReads += 1
        }
        try read()
        switch change {
        case "application": front = nil
        case "terminated": live = false
        case "window": selected = .init(application: app, root: original, window: other, element: original)
        case "field": selected = .init(application: app, root: original, window: original, element: other)
        case "unowned": owned = false
        case "webArea": area = other
        case "documentURL": address = "test://two"
        default:
            try read()
            #expect(semanticsReads == 2 && focusReads == 2 && metadataReads == 2)
            return
        }
        #expect(throws: NativeInputError.self) { try read() }
        #expect(semanticsReads == 1)
        #expect(focusReads == (change == "application" ? 1 : 2))
        #expect(metadataReads == (["webArea", "documentURL"].contains(change) ? 2 : 1))
    }

    private func fixture(prepare: (SelectedField) -> Void = { _ in },
                         expired: @escaping () -> Bool = { false }) async throws -> (VoiceModule, SelectedField, URL) {
        let dir = VoiceTests().directory()
        let store = try SaytileStore(directory: dir)
        let field = SelectedField()
        prepare(field)
        for (offset, text) in ["合成一", "第二段"].enumerated() {
            let record = try await store.createRecording(createdAt: Date(timeIntervalSince1970: Double(offset + 10)))
            _ = try await store.saveEdit(recordingID: record.id, text: text)
        }
        let module = VoiceModule(openStore: { store }, makeManualInput: {
            try NearpaneManualInsertion(store: $0, access: field, expired: expired)
        }, makeInput: { _, update in Issue.record("A manual insertion opened audio"); return ScriptedInput(update) })
        try module.start()
        await module.waitForTransition()
        return (module, field, dir)
    }

    @Test func directGestureConfirmsSelectedRevisionsAndReleasesTarget() async throws {
        let (module, field, dir) = try await fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(field.readCount == 0 && field.observed == nil && field.sent.isEmpty)
        let action = try #require(module.insertDisplayedText())
        #expect(module.insertDisplayedText() == nil)
        await action.value
        #expect(field.sent == ["合成一", "第二段"])
        #expect(module.insertionNotice == "已插入 2 段文字。" && field.observed == nil && !module.inserting)
        module.stop(); await module.waitForTransition()
    }

    @Test func uncertainWriteStopsRemainingRowsSurvivesRestartWithoutReplay() async throws {
        let (module, field, dir) = try await fixture(prepare: { $0.evidence = false })
        defer { try? FileManager.default.removeItem(at: dir) }
        await module.insertDisplayedText()?.value
        #expect(field.sent == ["合成一"] && module.insertionNotice == NativeInputResult.unverified.message)
        module.stop(); await module.waitForTransition()
        let restarted = VoiceModule(directory: dir, requireExistingPermissions: true, allowManualInsertion: true)
        try restarted.start(); await restarted.waitForTransition()
        #expect(!restarted.offersManualInput && restarted.insertDisplayedText() == nil && restarted.rows.count == 2)
        #expect(field.sent.count == 1)
        restarted.stop(); await restarted.waitForTransition()
    }

    @Test(arguments: ["field", "window", "caret", "revoked", "expired", "shutdown"])
    func targetMustRemainTheSameFromTheSynchronousGesture(change: String) async throws {
        var expired = false
        let (module, field, dir) = try await fixture(expired: { expired })
        defer { try? FileManager.default.removeItem(at: dir) }
        let action = try #require(module.insertDisplayedText())
        switch change {
        case "field": field.target.elementID = UUID()
        case "window": field.target.windowID = UUID()
        case "caret": field.target.selectionLocation = 1
        case "revoked": field.observed?(.focusOrDocument)
        case "expired": expired = true
        default: module.stop()
        }
        await action.value
        #expect(field.sent.isEmpty && field.observed == nil)
        module.stop(); await module.waitForTransition()
    }

    @Test(arguments: ["unauthorized", "clipboardOnly", "sensitive", "selection", "incompleteWeb"])
    func unsupportedOrPrivateRoutesAreRejectedBeforeDispatch(reason: String) async throws {
        let (module, field, dir) = try await fixture(prepare: { field in
            switch reason {
            case "unauthorized": field.hasPermission = false
            case "clipboardOnly": field.target.canSetSelectedText = false
            case "sensitive": field.target.isSensitive = true
            case "incompleteWeb": field.target.isWeb = true; field.target.pageContextComplete = false
            default: field.target.selectionLength = 2
            }
        })
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(module.insertDisplayedText() == nil)
        #expect(field.sent.isEmpty && field.observed == nil)
        if reason == "unauthorized" { #expect(field.readCount == 0) }
        module.stop(); await module.waitForTransition()
    }
}
