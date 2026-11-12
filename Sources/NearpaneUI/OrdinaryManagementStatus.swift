import SwiftUI
import NearpaneCore

private typealias ViewState<T> = State<T>

/// A verified write is reported by the live controller; a preview alone never adds a row here.
@MainActor struct OrdinaryManagementStatus: View {
    let manager: CandidateWorkRect
    private var session: OrdinaryWindowManager { manager.ordinary }
    @ViewState private var percent = 60
    @ViewState private var confirmingKeep = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.message).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("ordinary-status")
            if !session.activeIDs.isEmpty {
                ForEach(session.activeIDs, id: \.self) { id in
                    HStack {
                        Text(session.managedWindowLabel(id) + " · " + (session.verifiedIDs.contains(id) ? "布局已读回" : "待核对"))
                            .accessibilityIdentifier("ordinary-owner-\(id.number)")
                        Button("排除并停止管理") { perform { try await session.exclude(id, context: try current()) } }
                            .disabled(session.blocked).accessibilityIdentifier("ordinary-exclude-\(id.number)")
                    }.font(.caption)
                }
                HStack {
                    Button(session.paused ? "继续逐窗管理" : "暂停逐窗管理") {
                        perform { if session.paused { try await session.resume(context: try current()) } else { try session.pause() } }
                    }.disabled(session.blocked).accessibilityIdentifier(session.paused ? "ordinary-resume" : "ordinary-pause")
                    Button("停止并尝试恢复原位置") { perform { try await session.stop() } }.accessibilityIdentifier("ordinary-stop")
                }
                if session.activeIDs.count == 2 && !session.paused && !session.blocked {
                    HStack {
                        Stepper("左侧 \(percent)%", value: $percent, in: 20...80)
                        Button("应用双窗比例") {
                            perform {
                                var c = try current()
                                c.pairCustomized = true
                                c.ratio = Double(percent) / 100
                                try await session.update(context: c)
                            }
                        }.accessibilityIdentifier("ordinary-pair")
                    }
                }
            }
            if session.blocked {
                Button("保留当前位置并结束本次恢复…") { confirmingKeep = true }
                    .accessibilityIdentifier("ordinary-keep-current")
                    .confirmationDialog("保留当前窗口位置？原恢复记录将归档，不再调整窗口。", isPresented: $confirmingKeep) {
                        Button("确认保留当前位置") { perform { try session.keepCurrent() } }
                    }
            }
        }.disabled(session.unavailableForUserAction)
    }

    private func current() throws -> AdmissionContext {
        guard let display = session.activeDisplay, let c = manager.context(for: display) else {
            throw OrdinaryWindowFailure("无法核对当前副屏工作区域或管理范围。")
        }
        return c
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await session.performUserAction(action) }
            catch { session.report(error) }
        }
    }
}
