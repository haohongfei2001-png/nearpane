#if canImport(RiftletFeedback)
import AppKit
import SwiftUI
import NearpaneCore
import RiftletFeedback

private typealias ViewState<Value> = State<Value>

@MainActor
public final class ProductFeedbackController: ObservableObject {
    public static let repository = "haohongfei2001-png/Riftlet-Feedback"
    public static let endpoint = URL(string: "https://riftlet-feedback-receiver.haohongfei2001.workers.dev/v1/feedback")!

    @Published public var expanded = false
    @Published public private(set) var content = ProductFeedbackContent()
    @Published public private(set) var preview: ProductFeedbackPreview?
    @Published public private(set) var records: [FeedbackRecord] = []
    @Published public private(set) var notice: String?
    @Published public private(set) var ready = false
    @Published public private(set) var busy = false
    @Published public private(set) var stopping = false
    public let networkAllowed: Bool
    public let appVersion: String
    private let directory: URL
    private let systemVersion: String
    private let transport: any FeedbackTransport
    private let secrets: any FeedbackSecretStorage
    private let persistDraft: @Sendable (FeedbackDraft, FeedbackStore) async throws -> Void
    private let markClean: @Sendable (FeedbackStore) async throws -> Void
    private var engine: FeedbackEngine?
    private var revision: Int64 = 0
    private var starting = false
    private var saveTask: Task<Void, Never>?

    public convenience init(directory: URL, appVersion: String, networkAllowed: Bool) {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let transport: any FeedbackTransport
        if networkAllowed, let service = try? HTTPSFeedbackTransport(endpoint: Self.endpoint) {
            transport = service
        } else { transport = DisabledFeedbackTransport() }
        let secrets: any FeedbackSecretStorage = networkAllowed
            ? KeychainFeedbackSecrets(namespace: "com.holdsnow.nearpane.alpha") : MemoryFeedbackSecrets()
        self.init(directory: directory, appVersion: appVersion,
                  systemVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                  transport: transport, secrets: secrets)
    }

    init(directory: URL, appVersion: String, systemVersion: String,
         transport: any FeedbackTransport, secrets: any FeedbackSecretStorage,
         persistDraft: @escaping @Sendable (FeedbackDraft, FeedbackStore) async throws -> Void = { draft, store in try await store.saveDraft(draft) },
         markClean: @escaping @Sendable (FeedbackStore) async throws -> Void = { store in try await store.markClean() }) {
        self.directory = directory
        self.appVersion = appVersion
        self.systemVersion = systemVersion
        self.transport = transport
        self.secrets = secrets
        self.persistDraft = persistDraft
        self.markClean = markClean
        networkAllowed = transport.configured
    }

    public func start() async {
        guard !ready, !starting, !stopping else { return }
        starting = true
        defer { starting = false }
        do {
            let root = directory
            let store = try await Task.detached(priority: .utility) { try FeedbackStore(directory: root) }.value
            guard !stopping else { try await store.markClean(); return }
            let loaded = try await store.draft()
            revision = loaded.revision
            content = ProductFeedbackContent.restore(body: loaded.text, kind: ProductFeedbackKind(rawValue: loaded.kind.rawValue) ?? .problem)
            if storedDraft.text != loaded.text {
                guard revision < Int64.max - 1 else { throw FeedbackFailure.storageUnavailable }
                revision += 1
            }
            let active = FeedbackEngine(store: store, secrets: secrets, transport: transport)
            engine = active
            ready = true
            await active.pump()
            await refreshRecords()
        } catch { notice = "无法打开本机反馈记录。草稿尚未发送，请稍后重试。" }
    }

    public func edit(_ change: (inout ProductFeedbackContent) -> Void) {
        guard ready, !busy, !stopping, revision < Int64.max - 1 else { return }
        change(&content)
        revision += 1
        preview = nil
        notice = nil
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            _ = await self?.saveDraft()
        }
    }

    public func preparePreview() {
        do { preview = try content.preview(appVersion: appVersion, systemVersion: systemVersion, revision: revision); notice = nil }
        catch ProductFeedbackError.empty { notice = "请先写下遇到的问题或建议。" }
        catch { notice = "内容过长，请缩短后再预览。" }
    }

    public func sendPreview() async {
        guard ready, networkAllowed, !busy, !stopping, let engine, let preview else { return }
        do {
            guard preview == (try content.preview(appVersion: appVersion, systemVersion: systemVersion, revision: revision)) else {
                throw ProductFeedbackError.stalePreview
            }
            busy = true
            defer { busy = false }
            saveTask?.cancel()
            let draft = FeedbackDraft(kind: FeedbackKind(rawValue: preview.kind.rawValue)!, text: preview.body, revision: preview.revision)
            _ = try await engine.enqueue(draft, appVersion: preview.appVersion)
            let fresh = try await engine.store.draft()
            revision = fresh.revision
            content = ProductFeedbackContent()
            self.preview = nil
            notice = "已保存在本机反馈记录中。"
            await refreshRecords()
            await engine.pump()
            await refreshRecords()
        } catch { notice = "反馈未完成提交，文字已保留。请检查本机记录后重试。" }
    }

    public func refresh(id: String) async {
        guard !busy, !stopping, let engine else { return }
        busy = true
        defer { busy = false }
        do { try await engine.refresh(id: id); notice = nil }
        catch { notice = "暂时无法取得最新回执，本机记录已保留。" }
        await refreshRecords()
    }

    public func delete(id: String) async {
        guard !busy, !stopping, let engine else { return }
        busy = true
        defer { busy = false }
        do { try await engine.requestDeletion(id: id); notice = "删除状态将显示在这条反馈下方。" }
        catch { notice = "删除申请尚未完成，本机记录和原状态已保留。" }
        await refreshRecords()
    }

    public func forget(id: String) async {
        guard !busy, !stopping, let engine else { return }
        busy = true
        defer { busy = false }
        do { try await engine.forgetResolved(id: id); notice = nil }
        catch { notice = "本机记录尚未移除，请稍后重试。" }
        await refreshRecords()
    }

    public func prepareForTermination() async -> Bool {
        guard !busy, !starting else { expanded = true; notice = "反馈操作正在完成，请稍后退出。"; return false }
        // Freeze edits before any await. An accepted save may already be inside
        // SQLite when its task is cancelled, so join it before the final flush.
        stopping = true
        let acceptedSave = saveTask
        saveTask = nil
        acceptedSave?.cancel()
        await acceptedSave?.value
        guard await saveDraft() else { stopping = false; expanded = true; return false }
        await engine?.stop()
        await engine?.finishCurrentFlight()
        do {
            if let engine { try await markClean(engine.store) }
            return true
        } catch {
            expanded = true
            notice = "反馈已停止，退出状态尚未保存。请恢复存储条件后再次退出。"
            return false
        }
    }

    public func observeVisibleRecords() async {
        while expanded, ready, !stopping, !Task.isCancelled {
            await refreshRecords()
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
    }

    private func saveDraft() async -> Bool {
        guard ready, let engine else { return true }
        do {
            try await persistDraft(storedDraft, engine.store)
            return true
        } catch { notice = "草稿尚未保存，请保持此窗口打开并稍后重试。"; return false }
    }

    private var storedDraft: FeedbackDraft {
        let text = content.text.isEmpty && content.area == .general && !content.includeSystemVersion
            ? "" : content.body(systemVersion: systemVersion)
        return FeedbackDraft(kind: FeedbackKind(rawValue: content.kind.rawValue)!, text: text, revision: revision)
    }

    private func refreshRecords() async {
        do { records = try await engine?.store.records() ?? [] }
        catch { notice = "无法读取反馈状态，原记录仍保留。" }
    }
}

public struct ProductFeedbackSettings: View {
    @ObservedObject private var controller: ProductFeedbackController
    @ViewState private var deletionID: String?

    public init(controller: ProductFeedbackController) { self.controller = controller }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup(isExpanded: $controller.expanded) {
                if controller.expanded {
                    editor.task {
                        await controller.start()
                        await controller.observeVisibleRecords()
                    }
                }
            } label: {
                Text("反馈与建议").accessibilityIdentifier("np.feedback.open")
            }
        }
        .confirmationDialog("申请删除这条反馈？已经进入私有反馈中心的副本需要维护者处理，结果以服务回执为准。",
                            isPresented: Binding(get: { deletionID != nil }, set: { if !$0 { deletionID = nil } })) {
            Button("申请删除", role: .destructive) {
                if let id = deletionID { Task { await controller.delete(id: id) } }
                deletionID = nil
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("发送到 Nearpane 的私有反馈记录，与 Riftlet 共用反馈中心并按产品和模块区分。无需 GitHub 账号。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Picker("类型", selection: Binding(get: { controller.content.kind }, set: { value in controller.edit { $0.kind = value } })) {
                    ForEach(ProductFeedbackKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("模块", selection: Binding(get: { controller.content.area }, set: { value in controller.edit { $0.area = value } })) {
                    ForEach(ProductFeedbackArea.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
            TextEditor(text: Binding(get: { controller.content.text }, set: { value in controller.edit { $0.text = value } }))
                .frame(minHeight: 90, maxHeight: 140)
                .accessibilityLabel("反馈内容").accessibilityIdentifier("np.feedback.text")
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
            Toggle("附上 macOS 版本", isOn: Binding(get: { controller.content.includeSystemVersion }, set: { value in controller.edit { $0.includeSystemVersion = value } }))
            Text("只发送预览中的文字、Nearpane 版本及反馈编号。请避免填写私人内容。截图、录音、文档、路径和日志不会自动附上。")
                .font(.caption).foregroundStyle(.secondary)
            Button("预览将发送的内容") { controller.preparePreview() }
                .accessibilityIdentifier("np.feedback.preview")
            if let preview = controller.preview {
                Text("Nearpane \(preview.appVersion) · \(preview.kind.label)").font(.caption)
                Text(preview.body).font(.callout).textSelection(.enabled)
                Button(controller.busy ? "正在处理…" : "确认发送反馈") { Task { await controller.sendPreview() } }
                    .disabled(!controller.networkAllowed).accessibilityIdentifier("np.feedback.send")
            }
            if !controller.networkAllowed { Text("当前隔离环境只保存本机草稿。反馈发送已停用。").font(.caption) }
            if let notice = controller.notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
            if !controller.ready { Button("重新打开反馈记录") { Task { await controller.start() } } }
            if !controller.records.isEmpty {
                DisclosureGroup("反馈记录（\(controller.records.count)）") {
                    ForEach(controller.records, id: \.id) { record in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(record.created, style: .date).font(.caption)
                            Text(record.label).font(.callout)
                            DisclosureGroup("查看内容") { Text(record.envelope.text).font(.caption).textSelection(.enabled) }
                            HStack {
                                if record.state == .cancelled || record.state == .deleted {
                                    Button("移除本机记录") { Task { await controller.forget(id: record.id) } }
                                } else {
                                    Button("刷新状态") { Task { await controller.refresh(id: record.id) } }.disabled(!controller.networkAllowed)
                                    Button(record.attempts == 0 ? "取消投递" : "申请删除") { deletionID = record.id }
                                }
                            }
                            Divider()
                        }
                    }
                }
            }
        }.disabled(controller.busy || controller.stopping)
    }
}
#endif
