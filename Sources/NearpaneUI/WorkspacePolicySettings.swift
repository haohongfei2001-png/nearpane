import NearpaneCore
import SwiftUI
import UniformTypeIdentifiers

private typealias ViewState<T> = State<T>
struct WorkspacePolicySettings: View {
    let host: HostSession
    let showWindowManagement: () -> Void
    @ViewState private var choosingApplication = false
    @ViewState private var applicationError: String?
    static func exclusionIdentifier(at url: URL) -> String? {
        guard url.isFileURL, url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url),
              bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
              let executable = bundle.executableURL, FileManager.default.isExecutableFile(atPath: executable.path),
              let id = bundle.bundleIdentifier, !id.isEmpty, id.count <= 255,
              !id.contains(where: \.isWhitespace) else { return nil }
        return id
    }
    private func applicationName(_ id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
              let bundle = Bundle(url: url), bundle.bundleIdentifier == id else { return id }
        return bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ??
            bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
    }
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
                Section("点击墙纸显示桌面") {
                    Text("在「系统设置 → 桌面与程序坞 → 显示桌面」选择始终允许点击墙纸。点击墙纸可移开窗口，再点一次可恢复原布局。桌面项目的显示由 macOS 单独设置。")
                        .font(.caption)
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") {
                        Link("打开桌面与程序坞设置", destination: url)
                    }
                }
                Button("选择要排除的应用…") {
                    applicationError = nil
                    choosingApplication = true
                }
                .fileImporter(isPresented: $choosingApplication, allowedContentTypes: [.applicationBundle]) { result in
                    do {
                        let url = try result.get()
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        guard let id = Self.exclusionIdentifier(at: url) else {
                            applicationError = "无法确认所选应用的身份。"; return
                        }
                        edit { $0.excludedApps.insert(id) }
                    } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError {
                        return
                    } catch { applicationError = "无法读取所选应用。请重新选择。" }
                }
                if let applicationError { Text(applicationError).font(.caption) }
                if let unsaved = host.unsavedWorkspacePreferences {
                    Text("窗口规则未保存，普通窗口写入已暂停。").font(.caption)
                    Button("重试保存") { host.setWorkspacePreferences(unsaved) }
                }
                ForEach(prefs.excludedApps.sorted(), id: \.self) { bundle in
                    HStack {
                        Text(applicationName(bundle)).help(bundle)
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
                Button("选择窗口并设置规则…", action: showWindowManagement)
                ForEach(
                    Array(prefs.windows.keys).sorted {
                        ($0.pid, $0.number, $0.element.uuidString) < ($1.pid, $1.number, $1.element.uuidString)
                    }, id: \.self
                ) { id in
                    HStack {
                        Text("窗口 \(id.number) · \(prefs.windows[id] == .exclude ? "排除规则" : "单窗例外")")
                        Button("清除此窗规则") { edit { $0.windows[id] = nil } }
                    }
                }
                Text("单窗例外仅适用于选定的窗口。调整窗口位置仍需在「窗口管理」中授权。").font(.caption)
            }.padding()
        }
    }
}
