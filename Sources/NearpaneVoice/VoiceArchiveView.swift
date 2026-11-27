import SwiftUI
import SaytileKit

private typealias ViewState<Value> = State<Value>

struct VoiceArchiveRow: Identifiable {
    let paragraph: TimelineParagraph
    let preview: String
    var id: Int64 { paragraph.id }

    // A recording keeps its original civil day and timezone when the Mac travels.
    func timestamp(date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle) -> String {
        let zone = TimeZone(secondsFromGMT: paragraph.groupUTCOffset) ?? .gmt
        let locale = time == .omitted ? Locale(identifier: "zh_CN") : Locale(identifier: "en_GB")
        return paragraph.groupStart.formatted(Date.FormatStyle(date: date, time: time, locale: locale, timeZone: zone))
    }
}

struct VoiceArchivePage {
    let rows: [VoiceArchiveRow]
    let hasOlder: Bool
    let hasNewer: Bool
}

extension VoiceModule {
    func archivePage(_ window: TimelineWindow, query: String, limit: Int = 24) async throws -> VoiceArchivePage {
        try await withArchiveRead { store in
            let page = try await store.archiveParagraphPage(window, query: query, filter: .all, limit: limit)
            var rows: [VoiceArchiveRow] = []
            for paragraph in page.paragraphs.reversed() {
                try Task.checkCancellation()
                let first = try await store.paragraphMembers(paragraphID: paragraph.id, limit: 1)
                rows.append(.init(paragraph: paragraph, preview: first.entries.first?.recording.text ?? ""))
            }
            return VoiceArchivePage(rows: rows, hasOlder: page.hasOlder, hasNewer: page.hasNewer)
        }
    }

    func archiveMembers(of id: Int64, window: TimelineWindow, limit: Int = TimelinePage.capacity) async throws -> TimelinePage {
        try await withArchiveRead { try await $0.paragraphMembers(paragraphID: id, window, limit: limit) }
    }

    func archiveVersions(of id: UUID) async throws -> (revisions: [TranscriptRevision], draft: String?) {
        try await withArchiveRead { store in
            let revisions = try await store.revisions(recordingID: id)
            return (revisions, try await store.loadDraft(recordingID: id))
        }
    }
}

/// Uses the same recording store and generation as the edge panel. Opening the archive never starts capture.
public struct VoiceArchiveView: View {
    let module: VoiceModule
    let openSettings: () -> Void

    public init(module: VoiceModule, openSettings: @escaping () -> Void) {
        self.module = module
        self.openSettings = openSettings
    }

    public var body: some View {
        VoiceArchiveBrowser(module: module, openSettings: openSettings)
            .id(ObjectIdentifier(module))
    }
}

private struct ArchiveRequest: Equatable {
    let window: TimelineWindow
    let revision: Int
    var query = ""
}

private struct VoiceArchiveBrowser: View {
    let module: VoiceModule
    let openSettings: () -> Void
    @ViewState private var selected: VoiceArchiveRow?
    @ViewState private var query = ""
    @ViewState private var window: TimelineWindow = .latest
    @ViewState private var page: VoiceArchivePage?
    @ViewState private var failed = false

    var body: some View {
        GeometryReader { geometry in
            let sideBySide = geometry.size.width >= 720
            HStack(alignment: .top, spacing: 12) {
                if selected == nil || sideBySide {
                    list.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                if let selected {
                    if sideBySide { Divider() }
                    VoiceArchiveDetail(module: module, row: selected, leave: { self.selected = nil })
                        .id(selected.id)
                        .frame(maxWidth: sideBySide ? min(360, geometry.size.width * 0.43) : .infinity,
                               maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索文字、历史修订或草稿", text: $query).textFieldStyle(.plain)
                    .accessibilityLabel("搜索语音档案").accessibilityIdentifier("voice-archive-search")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("清除搜索")
                }
            }
            .padding(.horizontal, 10).frame(height: 34)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary).allowsHitTesting(false) }
            if failed {
                ContentUnavailableView {
                    Label("无法读取语音档案", systemImage: "externaldrive.badge.exclamationmark")
                } actions: {
                    Button("语音设置", action: openSettings)
                }
            } else if let page {
                if page.rows.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "还没有语音档案" : "没有匹配的语音", systemImage: "waveform",
                        description: query.isEmpty ? Text("完成一次收音后，可以在这里查看文字和修订。") : nil)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(page.rows.enumerated()), id: \.element.id) { index, item in
                                let previous = index == 0 ? nil : page.rows[index - 1].paragraph
                                let startsDay = previous?.groupDay != item.paragraph.groupDay
                                let startsGroup = startsDay || previous?.group != item.paragraph.group
                                if startsDay {
                                    Text(item.timestamp(date: .long, time: .omitted))
                                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                                        .padding(.top, index == 0 ? 5 : 16).padding(.bottom, 7)
                                        .accessibilityAddTraits(.isHeader)
                                } else if startsGroup {
                                    Divider().padding(.vertical, 4)
                                }
                                Button {
                                    selected = item
                                } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                                        if startsGroup {
                                            Text(item.timestamp(date: .omitted, time: .shortened))
                                                .font(.system(size: 12, weight: .medium)).monospacedDigit()
                                                .foregroundStyle(.secondary).fixedSize()
                                                .frame(minWidth: 42, alignment: .leading)
                                        } else {
                                            Color.clear.frame(width: 42, height: 1).accessibilityHidden(true)
                                        }
                                        Text(item.preview.isEmpty ? "无转写文字" : item.preview)
                                            .font(.system(size: 14)).lineSpacing(2)
                                            .lineLimit(3).multilineTextAlignment(.leading)
                                        Spacer(minLength: 4)
                                        if item.paragraph.isPinned {
                                            Image(systemName: "star.fill").foregroundStyle(.tint).accessibilityLabel("已收藏")
                                        }
                                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, 6).padding(.vertical, 7)
                                    .background {
                                        if selected?.id == item.id {
                                            RoundedRectangle(cornerRadius: 7).fill(.tint.opacity(0.12))
                                        }
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    if page.hasOlder || page.hasNewer {
                        HStack {
                            Button("较新语音") {
                                if let newest = page.rows.first { window = .starting(at: newest.id + 1) }
                            }.disabled(!page.hasNewer)
                            Button("较早语音") {
                                if let oldest = page.rows.last { window = .ending(at: oldest.id - 1) }
                            }.disabled(!page.hasOlder)
                        }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: query) { selected = nil; window = .latest; page = nil }
        .task(id: ArchiveRequest(window: window, revision: module.archiveRevision, query: query)) {
            do {
                if !query.isEmpty { try await Task.sleep(for: .milliseconds(160)) }
                page = try await module.archivePage(window, query: query)
                failed = false
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { failed = true; page = nil }
            }
        }
    }
}

private struct VoiceArchiveDetail: View {
    let module: VoiceModule
    let row: VoiceArchiveRow
    let leave: () -> Void
    @ViewState private var window: TimelineWindow = .starting(at: 0)
    @ViewState private var members: TimelinePage?
    @ViewState private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: leave) { Label("返回语音档案", systemImage: "chevron.left") }
                .accessibilityIdentifier("voice-archive-back")
            HStack {
                Text(row.paragraph.started, format: .dateTime.year().month().day().hour().minute())
                    .font(.headline)
                Spacer()
                if row.paragraph.hasAudio {
                    if module.archivePlaybackParagraph == row.id {
                        Button("停止回放", systemImage: "stop.fill") { module.stopArchivePlayback() }
                    } else {
                        Button("回听原音", systemImage: "play.fill") { module.playArchiveParagraph(row.paragraph) }
                            .disabled(!module.canPlayArchive)
                            .help(module.canPlayArchive ? "播放这段语音保存的原音" : "请先暂停收音再回听")
                    }
                }
            }
            if let issue = module.archivePlaybackIssue { Text(issue).font(.caption).foregroundStyle(.secondary) }
            if failed || members?.entries.isEmpty == true {
                Text("当前段落无法读取。").foregroundStyle(.secondary)
            } else if let members {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(members.entries) { entry in
                            VoiceArchiveFragment(module: module, recording: entry.recording)
                            Divider()
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if members.hasNewer || members.hasOlder {
                    HStack {
                        Button("上一页") {
                            if let first = members.entries.first { window = .ending(at: first.position - 1) }
                        }.disabled(!members.hasOlder)
                        Button("下一页") {
                            if let last = members.entries.last { window = .starting(at: last.position + 1) }
                        }.disabled(!members.hasNewer)
                    }
                }
            } else { ProgressView() }
        }
        .task(id: ArchiveRequest(window: window, revision: module.archiveRevision)) {
            do {
                members = try await module.archiveMembers(of: row.id, window: window)
                failed = false
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { failed = true; members = nil }
            }
        }
        .onDisappear { module.stopArchivePlayback() }
    }
}

private struct VoiceArchiveFragment: View {
    let module: VoiceModule
    let recording: Recording
    @ViewState private var expanded = false
    @ViewState private var versions: [TranscriptRevision]?
    @ViewState private var draft: String?
    @ViewState private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(recording.text.isEmpty ? "无转写文字" : recording.text)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(recording.createdAt, format: .dateTime.hour().minute().second())
                Text(state)
            }.font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("文字修订", isExpanded: $expanded) {
                if expanded {
                    VStack(alignment: .leading, spacing: 8) {
                        if failed {
                            Text("无法读取文字修订。")
                        } else if let versions {
                            if let draft { Text("未保存草稿").font(.caption); Text(draft).textSelection(.enabled) }
                            if versions.isEmpty, draft == nil { Text("没有文字修订").foregroundStyle(.secondary) }
                            ForEach(versions) { version in
                                HStack {
                                    Text(origin(version.origin))
                                    Text(version.createdAt, format: .dateTime.year().month().day().hour().minute().second())
                                    if recording.preferredRevisionID == version.id { Text("当前") }
                                }.font(.caption).foregroundStyle(.secondary)
                                Text(version.text).textSelection(.enabled)
                            }
                        } else { ProgressView().controlSize(.small) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .task(id: module.archiveRevision) {
                        do {
                            let result = try await module.archiveVersions(of: recording.id)
                            versions = result.revisions; draft = result.draft; failed = false
                        } catch is CancellationError {
                        } catch {
                            if !Task.isCancelled { failed = true; versions = nil; draft = nil }
                        }
                    }
                }
            }.controlSize(.small)
        }
    }

    private var state: String {
        if recording.isRecording { return "收音中" }
        return switch recording.recognitionState {
        case .queued: "等待识别"
        case .running: "识别中"
        case .completed: "识别完成"
        case .failed: "识别失败"
        case .cancelled: "识别已取消"
        }
    }

    private func origin(_ value: RevisionOrigin) -> String {
        switch value {
        case .partial: "中间识别"
        case .final: "最终识别"
        case .userEdit: "手工编辑"
        }
    }
}
