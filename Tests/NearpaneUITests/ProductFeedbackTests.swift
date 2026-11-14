#if canImport(RiftletFeedback)
import Foundation
import Testing
import RiftletFeedback
import NearpaneCore
@testable import NearpaneUI

private actor FeedbackRecorder: FeedbackTransport {
    nonisolated let configured = true
    let foreignReceipt: Bool
    private(set) var requests: [(FeedbackRequest, String, Data)] = []

    init(foreignReceipt: Bool = false) { self.foreignReceipt = foreignReceipt }

    func perform(_ action: FeedbackRequest, record: FeedbackRecord, secret: String) async throws -> FeedbackReceipt {
        requests.append((action, record.id, record.bytes))
        return FeedbackReceipt(id: foreignReceipt ? UUID().uuidString.lowercased() : record.id,
                               state: action == .delete ? "deleted" : "received")
    }
}

private actor FeedbackGate: FeedbackTransport {
    nonisolated let configured = true
    private var pending: CheckedContinuation<FeedbackReceipt, Never>?
    private var pendingID: String?
    private(set) var started = false

    func perform(_ action: FeedbackRequest, record: FeedbackRecord, secret: String) async throws -> FeedbackReceipt {
        started = true
        pendingID = record.id
        return await withCheckedContinuation { pending = $0 }
    }

    func release() {
        guard let pending, let pendingID else { return }
        self.pending = nil
        pending.resume(returning: FeedbackReceipt(id: pendingID))
    }
}

private actor FeedbackSaveGate {
    private var pending: CheckedContinuation<Void, Never>?
    private(set) var started = false
    private(set) var saved: FeedbackDraft?

    func persist(_ draft: FeedbackDraft, store: FeedbackStore) async throws {
        started = true
        await withCheckedContinuation { pending = $0 }
        try await store.saveDraft(draft)
        saved = draft
    }

    func release() {
        let continuation = pending
        pending = nil
        continuation?.resume()
    }
}

private actor FeedbackCleanFailure {
    private var failed = false

    func markClean(_ store: FeedbackStore) async throws {
        if !failed { failed = true; throw FeedbackFailure.storageUnavailable }
        try await store.markClean()
    }
}

@Suite("Nearpane private feedback")
@MainActor
struct ProductFeedbackUITests {
    private func fixture(transport: any FeedbackTransport) throws -> (URL, ProductFeedbackController) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NearpaneFeedback-" + UUID().uuidString)
        let controller = ProductFeedbackController(directory: root, appVersion: "5.9", systemVersion: "27.0",
                                                   transport: transport, secrets: MemoryFeedbackSecrets())
        return (root, controller)
    }

    @Test func openPreviewAndDraftChangesNeverSend() async throws {
        let transport = FeedbackRecorder()
        let (root, controller) = try fixture(transport: transport)
        defer { try? FileManager.default.removeItem(at: root) }
        await controller.start()
        #expect(controller.ready)
        controller.edit { $0.text = "合成反馈第一版" }
        controller.preparePreview()
        #expect(controller.preview != nil)
        controller.edit { $0.text = "修改后的合成反馈" }
        #expect(controller.preview == nil)
        await controller.sendPreview()
        #expect(await transport.requests.isEmpty)
        #expect(controller.records.isEmpty)
        #expect(await controller.prepareForTermination())
    }

    @Test func explicitSendFreezesProductAndSubmitsOnlyOnce() async throws {
        let transport = FeedbackRecorder()
        let (root, controller) = try fixture(transport: transport)
        defer { try? FileManager.default.removeItem(at: root) }
        await controller.start()
        controller.edit { $0.text = "测试反馈"; $0.area = .windows }
        controller.preparePreview()
        let preview = try #require(controller.preview)
        await controller.sendPreview()
        await controller.sendPreview()
        let requests = await transport.requests
        #expect(requests.count == 1)
        let payload = try JSONSerialization.jsonObject(with: requests[0].2) as! [String: Any]
        #expect(Set(payload.keys) == ["schema", "id", "kind", "text", "appVersion", "createdAt"])
        #expect(payload["text"] as? String == preview.body)
        #expect(payload["appVersion"] as? String == "5.9")
        #expect(controller.records.count == 1)
        #expect(controller.records.first?.state == .received)
        #expect(controller.content.text.isEmpty)
        #expect(await controller.prepareForTermination())
    }

    @Test func foreignReceiptDoesNotBecomeReceivedAndDeletionRemainsExplicit() async throws {
        let transport = FeedbackRecorder(foreignReceipt: true)
        let (root, controller) = try fixture(transport: transport)
        defer { try? FileManager.default.removeItem(at: root) }
        await controller.start()
        controller.edit { $0.text = "合成错误回执测试" }
        controller.preparePreview()
        await controller.sendPreview()
        #expect(controller.records.first?.state == .queued)
        #expect(controller.records.first?.attempts == 1)
        #expect(await transport.requests.count == 1)
        #expect(await controller.prepareForTermination())
    }

    @Test func draftRestartAndSharedServiceUseIndependentLocalStorage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NearpaneFeedbackRestart-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FeedbackStore(directory: root)
        var content = ProductFeedbackContent()
        content.area = .voice
        content.text = "保留\n多行草稿"
        let value = FeedbackDraft(kind: .suggestion, text: content.body(systemVersion: "27"), revision: 2)
        try await store.saveDraft(value)
        try await store.closeForTesting(clean: true)
        let reopened = try FeedbackStore(directory: root)
        let saved = try await reopened.draft()
        #expect(saved == value)
        #expect(ProductFeedbackContent.restore(body: saved.text, kind: .suggestion).text == content.text)
        #expect(try await reopened.records().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("queue.sqlite").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("saytile.sqlite").path))
        #expect(throws: FeedbackFailure.storageUnavailable) { try FeedbackStore(directory: root) }
        try await reopened.closeForTesting(clean: true)
    }

    @Test func unavailableEndpointKeepsDraftAndDoesNotEnqueue() async throws {
        let (root, controller) = try fixture(transport: DisabledFeedbackTransport())
        defer { try? FileManager.default.removeItem(at: root) }
        await controller.start()
        controller.edit { $0.text = "离线合成草稿" }
        controller.preparePreview()
        await controller.sendPreview()
        #expect(controller.content.text == "离线合成草稿")
        #expect(controller.records.isEmpty)
        #expect(await controller.prepareForTermination())
    }

    @Test func acceptedSendBlocksExitUntilReceiptIsPersisted() async throws {
        let transport = FeedbackGate()
        let (root, controller) = try fixture(transport: transport)
        defer { try? FileManager.default.removeItem(at: root) }
        await controller.start()
        controller.edit { $0.text = "等待回执的合成反馈" }
        controller.preparePreview()
        let sending = Task { await controller.sendPreview() }
        for _ in 0..<100 {
            if await transport.started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await transport.started)
        #expect(await controller.prepareForTermination() == false)
        #expect(controller.expanded)
        await transport.release()
        await sending.value
        #expect(controller.records.first?.state == .received)
        #expect(await controller.prepareForTermination())
    }

    @Test func explicitDeletionUsesOriginalIdentityBeforeLocalRemoval() async throws {
        let transport = FeedbackRecorder()
        let (root, controller) = try fixture(transport: transport)
        defer { try? FileManager.default.removeItem(at: root) }
        await controller.start()
        controller.edit { $0.text = "合成删除测试" }
        controller.preparePreview()
        await controller.sendPreview()
        let id = try #require(controller.records.first?.id)
        await controller.forget(id: id)
        #expect(controller.records.count == 1)
        #expect(await transport.requests.count == 1)
        await controller.delete(id: id)
        #expect(controller.records.first?.state == .deleted)
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.1 == id })
        await controller.forget(id: id)
        #expect(controller.records.isEmpty)
        #expect(await controller.prepareForTermination())
    }

    @Test func terminationFreezesEditsBeforeTheFinalSaveCanSuspend() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NearpaneFeedbackExit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = FeedbackSaveGate()
        let controller = ProductFeedbackController(directory: root, appVersion: "5.9", systemVersion: "27",
            transport: DisabledFeedbackTransport(), secrets: MemoryFeedbackSecrets(),
            persistDraft: { draft, store in try await gate.persist(draft, store: store) })
        await controller.start()
        controller.edit { $0.text = "退出前已接受的编辑" }
        let quitting = Task { await controller.prepareForTermination() }
        for _ in 0..<100 {
            if await gate.started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await gate.started)
        #expect(controller.stopping)
        controller.edit { $0.text = "退出期间不应再接受的编辑" }
        #expect(controller.content.text == "退出前已接受的编辑")
        await gate.release()
        #expect(await quitting.value)
        #expect(await gate.saved?.text.hasSuffix("退出前已接受的编辑") == true)
    }

    @Test func failedCleanMarkerKeepsSendingBlockedUntilExitRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NearpaneFeedbackClean-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = FeedbackCleanFailure()
        let transport = FeedbackRecorder()
        let controller = ProductFeedbackController(directory: root, appVersion: "5.9", systemVersion: "27",
            transport: transport, secrets: MemoryFeedbackSecrets(), markClean: { store in try await gate.markClean(store) })
        await controller.start()
        controller.edit { $0.text = "退出状态写入失败测试" }
        controller.preparePreview()
        #expect(await controller.prepareForTermination() == false)
        #expect(controller.stopping)
        await controller.sendPreview()
        controller.edit { $0.text = "不应进入已停止的引擎" }
        #expect(controller.content.text == "退出状态写入失败测试")
        #expect(await transport.requests.isEmpty)
        #expect(await controller.prepareForTermination())
    }

    @Test func systemUpgradeKeepsAnUnsentConsentedDraftWritable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NearpaneFeedbackVersion-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var original = ProductFeedbackContent()
        original.text = "系统升级前的未发送反馈"
        original.includeSystemVersion = true
        let store = try FeedbackStore(directory: root)
        try await store.saveDraft(FeedbackDraft(text: original.body(systemVersion: "27.0"), revision: 5))
        try await store.closeForTesting(clean: true)
        let controller = ProductFeedbackController(directory: root, appVersion: "5.9", systemVersion: "27.1",
                                                   transport: DisabledFeedbackTransport(), secrets: MemoryFeedbackSecrets())
        await controller.start()
        controller.preparePreview()
        #expect(controller.preview?.revision == 6)
        #expect(controller.preview?.body.contains("macOS=27.1") == true)
        #expect(controller.content.text == original.text)
        #expect(await controller.prepareForTermination())
    }
}
#endif
