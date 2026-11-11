import NearpaneCore
import SwiftUI

private typealias ViewState<T> = State<T>
struct WorkspacePolicySettings: View {
    let host: HostSession
    @ViewState private var app = ""
    @discardableResult private func edit(_ change: (inout WorkspacePreferences) -> Void) -> Bool {
        var prefs = host.workspacePreferencesDraft
        change(&prefs)
        return host.setWorkspacePreferences(prefs)
    }
    var body: some View {
        let prefs = host.workspacePreferencesDraft
        ScrollView {
            Form {
                Picker("普通新窗口", selection: Binding(get: { prefs.newWindow }, set: { v in edit { $0.newWindow = v } })) {
                    Text("优先进入独立工作空间").tag(NewWindowPlacement.newWorkspace)
                    Text("加入实际归属空间").tag(NewWindowPlacement.joinExisting)
                }
                Picker("超过八窗", selection: Binding(get: { prefs.overflow }, set: { v in edit { $0.overflow = v } })) {
                    Text("优先新建，受限时继续分割").tag(WindowOverflowPolicy.newAboveEight)
                    Text("继续分割").tag(WindowOverflowPolicy.continuousSplit)
                }
                HStack {
                    TextField("排除应用的 Bundle ID", text: $app)
                    Button("排除应用") {
                        if edit({ $0.excludedApps.insert(app) }) { app = "" }
                    }
                    .disabled(app.isEmpty || app.count > 255 || app.contains(where: \.isWhitespace))
                }
                if let unsaved = host.unsavedWorkspacePreferences {
                    Text("窗口规则未保存，普通窗口写入已暂停。").font(.caption)
                    Button("重试保存") { host.setWorkspacePreferences(unsaved) }
                }
                ForEach(prefs.excludedApps.sorted(), id: \.self) { bundle in
                    HStack {
                        Text(bundle)
                        Spacer()
                        Button("取消排除") { edit { $0.excludedApps.remove(bundle) } }
                    }
                }
                if let s = host.bus.desktop, let evidence = s.native {
                    let mode = evidence.stageManagerEnabled.map { $0 ? "开启" : "关闭" } ?? "未知"
                    Text("采样时台前调度状态：\(mode)").font(.caption)
                    if !s.nativeIsFresh(now: Date(), uptime: ProcessInfo.processInfo.systemUptime) {
                        Text("窗口观测尚未稳定，暂不可纳入管理。").font(.caption)
                    } else {
                        let count = s.windows.filter { $0.metadata?.presentation != .confirmed }.count
                        if count > 0 {
                            Text("\(count) 扇窗口的屏幕位置未确认，暂不可管理。").font(.caption)
                        }
                    }
                }
                if let s = host.bus.desktop, s.isStructurallyValid,
                    s.nativeIsFresh(now: Date(), uptime: ProcessInfo.processInfo.systemUptime)
                {
                    ForEach(s.windows) { w in
                        if let id = ManagedWindowID(w) {
                            HStack {
                                Text("进程 \(id.pid) · 窗口 \(id.number)")
                                Button("排除此窗") { setRule(.exclude, id: id, snapshot: s) }
                                Button("纳入此窗") { setRule(.include, id: id, snapshot: s) }
                                    .disabled(w.metadata?.presentation != .confirmed)
                            }
                        }
                    }
                }
                ForEach(
                    Array(prefs.windows.keys).sorted {
                        ($0.pid, $0.number, $0.element.uuidString) < ($1.pid, $1.number, $1.element.uuidString)
                    }, id: \.self
                ) { id in
                    HStack {
                        Text("窗口 \(id.number) · \(prefs.windows[id] == .exclude ? "已排除" : "明确纳入")")
                        Button("清除此窗规则") { edit { $0.windows[id] = nil } }
                    }
                }
                Text("窗口规则优先于应用规则。自动管理仅向已授权的兼容应用开放。").font(.caption)
            }.padding()
        }
    }
    private func setRule(_ rule: WindowRule, id: ManagedWindowID, snapshot: DesktopSnapshot) {
        guard host.bus.desktop == snapshot,
            snapshot.nativeIsFresh(now: Date(), uptime: ProcessInfo.processInfo.systemUptime),
            snapshot.windows.contains(where: { ManagedWindowID($0) == id && (rule == .exclude || $0.metadata?.presentation == .confirmed) })
        else { return }
        edit { $0.windows[id] = rule }
    }
}
