import SwiftUI
import NearpaneCore

private typealias ViewState<T> = State<T>

/// A verified write is reported by the live controller; a preview alone never adds a row here.
@MainActor struct OrdinaryManagementStatus: View {
    let manager: CandidateWorkRect
    private var session: OrdinaryWindowManager { manager.ordinary }
    @ViewState private var percent = 60
    @ViewState private var confirmingKeep = false
    @ViewState private var newWindowChoice: ManagedWindowID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.message).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("ordinary-status")
            if !session.activeIDs.isEmpty {
                if let display = session.activeDisplay,
                   let reason = manager.presentationPauseReason(on: display, uptime: ProcessInfo.processInfo.systemUptime) {
                    Text(reason).font(.caption).accessibilityIdentifier("ordinary-display-hold")
                }
                ForEach(session.activeIDs, id: \.self) { id in
                    HStack {
                        Text(session.managedWindowLabel(id) + " · " + (session.verifiedIDs.contains(id) ? "布局已读回" : "待核对"))
                            .accessibilityIdentifier("ordinary-owner-\(id.number)")
                        if session.creationAnchor == id {
                            Button("停止接纳新窗") { perform { session.disableNewWindows() } }
                                .accessibilityIdentifier("ordinary-scope-stop")
                        } else if session.desktopScope == nil && session.creationAnchor == nil && !session.paused && !session.blocked {
                            Button("接纳此应用新窗…") {
                                newWindowChoice = id
                            }.accessibilityIdentifier("ordinary-scope-offer-\(id.number)")
                        }
                        Button("排除并停止管理") { perform { try await session.exclude(id, context: try current()) } }
                            .disabled(session.blocked).accessibilityIdentifier("ordinary-exclude-\(id.number)")
                    }.font(.caption)
                }
                if let id = newWindowChoice, session.activeIDs.contains(id),
                   session.creationAnchor == nil, !session.paused, !session.blocked {
                    Text("仅管理“" + session.managedWindowLabel(id) + "”所属进程随后在此屏新建的合格窗口。已有其他窗口保持原样，暂停或关闭原窗口会结束授权。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("同意接纳新窗口") {
                            newWindowChoice = nil
                            perform { try await session.enableNewWindows(from: id) }
                        }.accessibilityIdentifier("ordinary-scope-confirm")
                        Button("取消") { newWindowChoice = nil }
                    }
                }
                HStack {
                    Button(session.paused ? "继续逐窗管理" : "暂停逐窗管理") {
                        perform { if session.paused { try await session.resume(context: try current()) } else { try session.pause() } }
                    }.disabled(session.blocked).accessibilityIdentifier(session.paused ? "ordinary-resume" : "ordinary-pause")
                    Button("停止并尝试恢复原位置") { perform { try await session.stop() } }.accessibilityIdentifier("ordinary-stop")
                }
                if session.activeIDs.count == 2 && !session.paused && !session.blocked {
                    HStack {
                        Stepper("左侧调至 \(percent)%", value: $percent, in: 20...80)
                        Button("应用比例") { perform { try await session.editPair(leftPercent: percent, swap: false, context: try current()) } }
                            .accessibilityIdentifier("ordinary-pair")
                        Button("交换左右") {
                            perform {
                                guard let slots = session.pairSlots else { throw OrdinaryRefusal.stale }
                                try await session.editPair(leftPercent: slots.percent, swap: true, context: try current())
                            }
                        }.accessibilityIdentifier("ordinary-swap")
                    }
                    if let slots = session.pairSlots {
                        Text("当前左侧占 \(slots.percent)%" + (session.hasCustomLayout ? "。退出应用时，已确认的槽位与比例将映射到完整工作区。" : ""))
                            .font(.caption).foregroundStyle(.secondary)
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
            throw OrdinaryWindowFailure("无法核对授权窗口所在显示器的工作区域或管理范围。")
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
