import AppKit
import Darwin
import NearpaneCore
#if !NEARPANE_WINDOW_SELECTION_FIXTURE
import NearpaneOrdinaryWindowRuntime
#endif
import Security

// This predicate identifies the owning bundle; verifyParent still requires its strict code seal.
// Candidate markers come from that bundle's Info.plist, never the helper's arguments or Bundle.main.
func ordinaryControllerParentMatches(helper: URL, host: URL, root: URL, declaredHost: URL?,
                                     identifier: String?, workspace: Any?, acceptance: Any?) -> Bool {
    let contents = helper.deletingLastPathComponent().deletingLastPathComponent()
    guard helper.lastPathComponent == "NearpaneOrdinaryWindowController",
          helper.deletingLastPathComponent().lastPathComponent == "Helpers",
          root.pathExtension == "app", contents.lastPathComponent == "Contents",
          contents.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
          host.lastPathComponent == "NearpaneHost", let declaredHost else { return false }
    #if NEARPANE_WINDOW_SELECTION_FIXTURE
    let requiredBundleID = "net.example.nearpane-sidebar-observer"
    #else
    let requiredBundleID = "com.holdsnow.nearpane.alpha"
    if identifier == IndependentStagePolicy.candidateBundleID {
        guard (workspace as? Int == 1 && acceptance == nil) ||
              (acceptance as? Int == 1 && workspace == nil) else { return false }
        // Resolve the containing bundle once (including /tmp -> /private/tmp), but do not
        // permit either sealed executable to redirect to a file elsewhere.
        let canonical = root.resolvingSymlinksInPath()
        let expectedHost = canonical.appendingPathComponent("Contents/MacOS/NearpaneHost")
        let expectedHelper = canonical.appendingPathComponent("Contents/Helpers/NearpaneOrdinaryWindowController")
        return expectedHost == expectedHost.resolvingSymlinksInPath() &&
            expectedHelper == expectedHelper.resolvingSymlinksInPath() &&
            host.resolvingSymlinksInPath() == expectedHost &&
            declaredHost.resolvingSymlinksInPath() == expectedHost &&
            helper.resolvingSymlinksInPath() == expectedHelper
    }
    #endif
    return identifier == requiredBundleID && declaredHost.standardizedFileURL == host.standardizedFileURL
}

// No command-line targeting: one sealed Host owns both pipes and the worker can bind only one
// same-user regular application. EOF or parent death discards all AX references.
func verifyParent(_ parent: pid_t) -> Bool {
    guard parent > 1, let own = windowExecutablePath(getpid()), let host = windowExecutablePath(parent) else { return false }
    let root = own.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard let bundle = Bundle(url: root),
          ordinaryControllerParentMatches(helper: own, host: host, root: root, declaredHost: bundle.executableURL,
              identifier: bundle.bundleIdentifier, workspace: bundle.object(forInfoDictionaryKey: "NearpaneIndependentStageWorkspace"),
              acceptance: bundle.object(forInfoDictionaryKey: "NearpaneIndependentStageAcceptance")) else { return false }
    // A clone with new code and copied Info.plist does not validate against the sealed app.
    var signed: SecStaticCode?
    guard SecStaticCodeCreateWithPath(root as CFURL, [], &signed) == errSecSuccess, let signed,
          SecStaticCodeCheckValidity(signed, SecCSFlags(rawValue:kSecCSStrictValidate), nil) == errSecSuccess
    else { return false }
    return true
}

final class Worker {
    let parent: pid_t
    let owner = OrdinaryOwnerIdentity()
    var app: (Int32,UInt64,String)?
    private var creationWatch: CreatedWindowWatch?
    private var creationHandles = Set<ManagedWindowID>()
    var windowsByID = [ManagedWindowID: WindowMonitor]()
    let previewWindow: UInt32?
    let scopeProbeOnly: Bool
    init(_ parent: pid_t, previewWindow: UInt32? = nil, scopeProbeOnly: Bool = false) {
        self.scopeProbeOnly = scopeProbeOnly
        self.parent = parent
        self.previewWindow = previewWindow
    }

    func handle(_ r: OrdinaryWindowRequest) -> OrdinaryWindowReply {
        var reply = OrdinaryWindowReply(r.nonce)
        do {
            try require(getppid() == parent, "调用方已退出。")
            guard r.action != .stageRead && r.action != .stagePlace && !(r.action == .watchCreated && r.desktop != nil)
            else { throw Refusal("调度组操作只可由当前正式 Host 的已登记窗口会话执行。") }
            if let scope = r.focusScope {
                try require((r.action == .inspectFocusScope || r.action == .focusCurrent) && r.id != nil && r.expected != nil &&
                    r.destination == nil && r.desktop == nil && r.pairPlacement == nil &&
                    r.focusDisplay == scope.desktop.display && r.focusSpace == scope.desktop.record &&
                    OrdinaryFocusScope(display: scope.desktop.display, topology: scope.topology, order: scope.order,
                                       physicalDisplay: scope.physicalDisplay, separateSpaces: scope.separateSpaces) == scope,
                    "定向读回与本次选窗不一致。")
            }
            if let placement = r.pairPlacement {
                try require(r.action == .write && (r.desktop == nil || r.desktop == placement.desktop), "双窗授权只能用于本次指定桌面的写入。")
            }
            if let previewWindow {
                let allowed = scopeProbeOnly ? r.action.allowedForFocusScopeProbe : r.action.allowedForStillPreview
                try require(allowed && r.destination == nil &&
                            (r.action == .list || r.id?.number == previewWindow), "此通道仅核对已选预览窗口。")
            }
            if r.action == .checkFocusPermission || r.action == .requestFocusPermission {
                try require(app == nil && r.pid == 0 && r.launch == 0 && r.bundle.isEmpty &&
                            r.id == nil && r.destination == nil, "权限检查不能指定窗口。")
                if r.action == .requestFocusPermission && !AXIsProcessTrusted() {
                    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                }
                reply.focusPermission = AXIsProcessTrusted()
                return reply
            }
            if r.action == .list || r.action == .refresh {
                try require(r.id == nil, "窗口清单只能按已选进程查询。")
                if r.action == .list {
                    try require(app == nil, "一个控制进程仅绑定一次应用。")
                } else {
                    guard let app, app == (r.pid,r.launch,r.bundle) else { throw Refusal("所选应用已变化。") }
                }
                if r.action == .list && !AXIsProcessTrusted() {
                    reply.listAccessDenied = true
                    throw Refusal("窗口助手没有现有辅助功能权限。")
                }
                try checkOwner(owner, pid:r.pid, launch:r.launch, bundle:r.bundle)
                app = (r.pid,r.launch,r.bundle)
                let all = try windows(r.pid)
                let numbers = all.map(number)
                let counts = Dictionary(grouping:numbers.compactMap { $0 }, by:{ $0 })
                let previous = windowsByID
                var retained = previous.filter { $0.value.hasObserver }
                reply.choices = all.enumerated().map { index,e -> ManagedWindowID? in
                    guard let n = numbers[index], counts[n]?.count == 1, previewWindow == nil || previewWindow == n else { return nil }
                    if let (id, existing) = previous.first(where: {
                        !creationHandles.contains($0.key) && $0.key.number == n && $0.value.canListAgain && CFEqual($0.value.element,e)
                    }) {
                        retained[id] = existing
                        return id
                    }
                    let id = ManagedWindowID(pid:r.pid,launch:r.launch,number:n,element:UUID())
                    retained[id] = WindowMonitor(id:id,bundle:r.bundle,element:e,parent:parent,owner:owner)
                    return id
                }
                try checkOwner(owner, pid:r.pid, launch:r.launch, bundle:r.bundle)
                if previewWindow != nil { reply.choices = reply.choices?.compactMap { $0 } }
                windowsByID = retained
            } else {
                guard let app, app == (r.pid,r.launch,r.bundle), let id = r.id,
                      let m = windowsByID[id] else { throw Refusal("窗口未在本次选择中登记。") }
                switch r.action {
                case .stageRead, .stagePlace:
                    throw Refusal("调度组操作只可由当前正式 Host 的已登记窗口会话执行。")
                case .inspectFocusScope:
                    guard let scope = r.focusScope, let frame = r.expected else { throw Refusal("缺少定向选窗读回凭据。") }
                    try checkOwner(owner, pid: id.pid, launch: id.launch, bundle: r.bundle)
                    let trace = CurrentFocusScope.Trace(includeConfirmed: scopeProbeOnly)
                    reply.focusScopeEvidence = CurrentFocusScope.inspect(scope, number: id.number, trace: trace) {
                        CurrentFocusScope.original(id, element: m.element, frame: frame, display: scope.desktop.display, trace: trace)
                    }
                    reply.focusScopeFindings = trace.findings
                    try checkOwner(owner, pid: id.pid, launch: id.launch, bundle: r.bundle)
                case .focusCurrent:
                    guard let expected = r.expected, let display = r.focusDisplay, let deadline = r.focusDeadline,
                          r.destination == nil else { throw Refusal("缺少当前桌面的选窗凭据。") }
                    var nextStep = 0
                    try focusCurrentWindow(id: id, element: m.element, owner: owner, bundle: r.bundle,
                                           frame: expected, display: display, deadline: deadline, space: r.focusSpace, scope: r.focusScope,
                                           timing: r.focusTimingID.map(WindowFocusTiming.init(id:))) {
                        var challenge = OrdinaryWindowReply(r.nonce)
                        challenge.focusStep = nextStep
                        let decision: NativeSpaceStepPermission
                        do {
                            decision = try SelectionStepHandshake.exchange(challenge, input: .standardInput, output: .standardOutput)
                        } catch { exit(75) } // Discard a late/partial response with this connection.
                        try require(getppid() == parent && AXIsProcessTrusted()
                                    && decision.permitsFocus(r, after: nextStep, now: ProcessInfo.processInfo.systemUptime), "原选窗意图已取消或超时。")
                        nextStep += 1
                    }
                case .prepare:
                    if let desktop = r.desktop { try m.bindDesktop(desktop) }
                    reply.pair = try m.prepare()
                case .observeBoundary:
                    guard let expected = r.expected else { throw Refusal("缺少已授权窗口基线。") }
                    do { reply.boundary = try m.observeBoundary(expected) }
                    catch let original as Refusal {
                        do { reply.closure = try m.closure(expected: expected) }
                        catch { throw original }
                    }
                case .acknowledgeBoundary:
                    guard let expected = r.expected, let current = r.destination, let revision = r.boundaryRevision else {
                        throw Refusal("边界观测缺少对应窗口事件。")
                    }
                    reply.pair = try m.acknowledgeBoundary(from: expected, current: current, revision: revision)
                case .verify:
                    guard let expected = r.expected else { throw Refusal("缺少窗口基线。") }
                    do { reply.pair = try m.verify(expected) }
                    catch let original as Refusal {
                        do { reply.closure = try m.closure(expected: expected) }
                        catch let closure as Refusal { throw Refusal(original.message + " " + closure.message) }
                    }
                case .write:
                    guard let expected = r.expected, let to = r.destination else { throw Refusal("缺少明确的窗口目标。") }
                    let retainedPeer = r.pairPlacement.flatMap { windowsByID[$0.left == id ? $0.right : $0.left] }
                    if let retainedPeer { try require(retainedPeer.canListAgain, "已登记的同伴窗口不再有效。") }
                    var completed = [OrdinaryWindowStep]()
                    defer { reply.steps = completed }
                    reply.pair = try m.write(from: expected, to: to, placement: r.pairPlacement,
                                             retainedPeer: retainedPeer?.element) { completed.append($0) }
                case .watchCreated:
                    try checkOwner(owner, pid: r.pid, launch: r.launch, bundle: r.bundle)
                    guard let token = r.creationGrant, m.canListAgain else { throw Refusal("原窗口授权已失效。") }
                    guard r.desktop == nil, m.hasObserver else { throw Refusal("原窗口授权已失效。") }
                    creationWatch = try CreatedWindowWatch(anchor: id, grant: token)
                case .endCreated:
                    if creationWatch?.anchor == id, creationWatch?.grant == r.creationGrant { creationWatch = nil }
                case .takeCreated:
                    try checkOwner(owner, pid: r.pid, launch: r.launch, bundle: r.bundle)
                    guard let watch = creationWatch, watch.anchor == id, watch.grant == r.creationGrant,
                          m.canListAgain else { throw Refusal("新窗口授权已失效。") }
                    if let (element, n) = try watch.take() {
                        let newID = ManagedWindowID(pid: r.pid, launch: r.launch, number: n, element: UUID())
                        let monitor = WindowMonitor(id: newID, bundle: r.bundle, element: element, parent: parent, owner: owner)
                        // Subscribe and verify before exposing a retained handle. A failed candidate
                        // was already consumed and cannot become a later retry.
                        do {
                            _ = try monitor.prepare()
                            windowsByID[newID] = monitor
                            creationHandles.insert(newID)
                            reply.created = newID
                        } catch {
                            monitor.stop()
                            reply.skippedCreated = (error as? Refusal)?.message ?? "新窗口未通过身份和几何核对。"
                        }
                    }
                case .release:
                    if creationWatch?.anchor == id { creationWatch = nil }
                    creationHandles.remove(id)
                    m.stop()
                    windowsByID.removeValue(forKey:id)
                case .list, .refresh, .checkFocusPermission, .requestFocusPermission: break
                }
            }
        } catch { reply.failure = (error as? Refusal)?.message ?? "无法核对系统窗口状态。" }
        return reply
    }
}

let parent = getppid()
guard verifyParent(parent) else { exit(64) }
let args = CommandLine.arguments.dropFirst()
let previewWindow: UInt32?
if args.isEmpty { previewWindow = nil }
else if args.count == 2, args.first == "--read-only-preview" || args.first == "--read-only-focus-scope",
        let number = UInt32(args.last!), number > 0 {
    previewWindow = number
} else { exit(64) }
let worker = Worker(parent, previewWindow: previewWindow, scopeProbeOnly: args.first == "--read-only-focus-scope")
final class CommandInput {
    let worker: Worker
    var pending = Data()
    init(_ worker: Worker) { self.worker = worker }
    func readable(_ fd: CFFileDescriptor) {
        guard getppid() == worker.parent else { exit(0) }
        var buffer = [UInt8](repeating:0,count:4096)
        let length = Darwin.read(CFFileDescriptorGetNativeDescriptor(fd),&buffer,buffer.count)
        guard length > 0 else { exit(0) }
        pending.append(contentsOf:buffer.prefix(length))
        guard pending.count <= 65_536 else { exit(64) }
        while let end = pending.firstIndex(of:10) {
            guard let command = try? JSONDecoder().decode(OrdinaryWindowRequest.self,from:pending[..<end]) else { exit(65) }
            pending.removeSubrange(...end)
            let reply = worker.handle(command)
            guard var data = try? JSONEncoder().encode(reply) else { exit(70) }
            data.append(10)
            do { try FileHandle.standardOutput.write(contentsOf:data) } catch { exit(0) }
        }
        CFFileDescriptorEnableCallBacks(fd, CFOptionFlags(kCFFileDescriptorReadCallBack))
    }
}

let input = CommandInput(worker)
var inputContext = CFFileDescriptorContext(version:0, info:Unmanaged.passUnretained(input).toOpaque(),
                                           retain:nil, release:nil, copyDescription:nil)
let inputCallback: CFFileDescriptorCallBack = { fd, _, info in
    guard let fd, let info else { exit(70) }
    Unmanaged<CommandInput>.fromOpaque(info).takeUnretainedValue().readable(fd)
}
guard let fd = CFFileDescriptorCreate(nil,STDIN_FILENO,false,inputCallback,&inputContext),
      let source = CFFileDescriptorCreateRunLoopSource(nil,fd,0) else { exit(70) }
CFRunLoopAddSource(CFRunLoopGetCurrent(),source,.defaultMode)
CFFileDescriptorEnableCallBacks(fd,CFOptionFlags(kCFFileDescriptorReadCallBack))
CFRunLoopRun()
