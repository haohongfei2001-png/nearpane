import SwiftUI

private typealias ViewState<T> = State<T>
struct DesktopItemsSettingsSection: View {
    @ViewState private var task: Task<Void, Never>?
    @ViewState private var status = ""

    var body: some View {
        Section("桌面文件和图标") {
            Menu("设置显示方式…") {
                ForEach(DesktopItemDisplay.allCases, id: \.self) { mode in
                    Button(mode.label) { choose(mode) }
                }
            }
            .accessibilityIdentifier("desktop-items-display-mode")
            .disabled(task != nil)
            Text(status.isEmpty ? "通过 macOS 的「显示项目」设置更改当前账户的桌面。选择「点击空白墙纸时显示」，使用应用时会隐藏桌面文件和图标。" : status)
                .font(.caption).foregroundStyle(.secondary)
        }
        .onDisappear {
            task?.cancel()
            task = nil
            status = ""
        }
    }

    private func choose(_ mode: DesktopItemDisplay) {
        guard task == nil else { return }
        status = "正在读取系统的「在桌面上」选项…"
        task = Task { @MainActor in
            let outcome = await DesktopItemsSetting.shared.choose(mode)
            guard !Task.isCancelled else { return }
            switch outcome {
            case .confirmed(let observed): status = "系统已确认桌面文件和图标的显示方式为「\(observed.label)」。"
            case .manual:
                status = mode == .onWallpaperClick
                    ? "请在已打开的系统设置中取消勾选「显示项目」下的「在桌面上」。"
                    : "请在已打开的系统设置中勾选「显示项目」下的「在桌面上」。"
            case .unconfirmed: status = "尚未确认更改结果，可在系统设置的「显示项目」中查看当前值。"
            case .unavailable: status = "无法打开「系统设置 → 桌面与程序坞 → 显示项目」。"
            case .busy: status = "正在处理上一次桌面显示更改。"
            }
            task = nil
        }
    }
}
