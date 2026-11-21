import AppKit
import CReadOnlySpaces
import NearpaneCore

/// The host owns a pipe to this child for its lifetime. Other processes cannot submit actions.
func isBundledChild() -> Bool {
    func executable(_ pid: pid_t) -> URL? {
        var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard pid > 1, proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { return nil }
        let path = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }
    guard let url = executable(getpid()), url.lastPathComponent == "NearpaneSpaceAction",
          url.deletingLastPathComponent().lastPathComponent == "Helpers" else { return false }
    let contents = url.deletingLastPathComponent().deletingLastPathComponent()
    return executable(getppid()) == contents.appendingPathComponent("MacOS/NearpaneHost")
}

/// The prepared bridge object is submitted at most once. A revoked, interrupted or
/// expired permit cannot authorize it, even if the exact-window check finishes later.
func submitPreparedMove<T>(_ request: NativeSpaceCommand, now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                           authorize: () throws -> NativeSpaceStepPermission,
                           verify: () throws -> Void, submit: (TimeInterval) -> T) throws -> T {
    guard request.action == .move, request.isFresh(at: now()) else { throw ActionFailure("迁移动作已过期。") }
    let permission = request.confirmMoveBeforeSubmission == true ? try authorize() : nil
    if let permission, !permission.permits(request, after: 0, now: now()) {
        throw ActionFailure("窗口调度已交还系统，请重新选择。")
    }
    try verify()
    let submitted = now()
    guard request.isFresh(at: submitted), permission?.permits(request, after: 0, now: submitted) != false else {
        throw ActionFailure("迁移动作已过期。")
    }
    return submit(submitted)
}

@MainActor
func run(_ request: NativeSpaceCommand, available: Bool, witnesses: SidebarWindowWitnesses) -> NativeSpaceReply {
    if let refusal = request.nativeWriteRefusal { return refusal }
    do {
        guard available, request.isFresh(at: ProcessInfo.processInfo.systemUptime) else {
            throw ActionFailure("当前系统窗口信息不可用或已过期。")
        }
        let start = try ActionInventory.read()
        switch request.action {
        case .probe:
            return .init(id: request.id, state: .ready, detail: "已读取系统空间状态。", canSwitch: false,
                         canMove: false, currentBefore: start.currents)
        case .observeWindows:
            guard let probes = request.observations, request.window == nil, request.originalWindow == nil else {
                throw ActionFailure("窗口观察请求不完整。")
            }
            var reasons = [NativeSpaceWindow: String](), fields = [NativeSpaceWindow: [String: String]]()
            var withheld = [Int]()
            let tokens = try witnesses.observe(probes, inventory: start, report: { reasons[$0] = $1 },
                                              facts: { fields[$0] = $1 }, withheld: { withheld.append($0) })
            return .init(id: request.id, state: .ready, detail: "已核对窗口身份。", canSwitch: false,
                         canMove: false, observedWindows: tokens,
                         observationReasons: reasons.isEmpty ? nil : probes.map { reasons[$0.location.window] },
                         observationWorkerPID: reasons.isEmpty ? nil : getpid(),
                         observationFacts: fields.isEmpty ? nil : probes.map { fields[$0.location.window] },
                         withheldOriginals: withheld.isEmpty ? nil : withheld)
        case .select, .move:
            throw ActionFailure("原生桌面由 macOS 管理。")
        }
    } catch {
        return .init(id: request.id, state: .failed, detail: (error as? ActionFailure)?.text ?? error.localizedDescription, canSwitch: false, canMove: false)
    }
}

if CommandLine.arguments.dropFirst() == ["--self-check"] {
    print("NearpaneSpaceAction schema=2; no action issued")
} else if CommandLine.arguments.dropFirst() == ["--serve"], isBundledChild() {
    let supported = NPReadOnlySpacesOpen() == 1
    let witnesses = SidebarWindowWitnesses()
    while let line = readLine(), isBundledChild() {
        guard line.utf8.count <= 16384,
              let request = try? JSONDecoder().decode(NativeSpaceCommand.self, from: Data(line.utf8))
        else { exit(65) }
        let result = autoreleasepool { run(request, available: supported, witnesses: witnesses) }
        guard let bytes = try? JSONEncoder().encode(result) else { exit(70) }
        FileHandle.standardOutput.write(bytes + Data([10]))
    }
} else { exit(64) }
