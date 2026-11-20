import AppKit
import CNativeSpaceActions
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

@MainActor
func run(_ request: NativeSpaceCommand, available: Bool, witnesses: SidebarWindowWitnesses,
         authorize: (NativeSpaceReply) throws -> NativeSpaceStepPermission) -> NativeSpaceReply {
    let canSwitch = available && NPDockInstalledProtocol() != NPDockUnsupported && CGPreflightPostEventAccess()
    let canMove = available && AXIsProcessTrusted() && NPMoveAvailable()
    var before: ActionInventory?, after: ActionInventory?
    var oldMembership: [String]?, newMembership: [String]?
    var trace = NativeSwitchTrace()
    var notifications: SpaceNotificationTimes?
    var issued = false
    var issuedAt: TimeInterval?, steps = 0
    func reply(_ state: NativeSpaceReply.State, _ text: String) -> NativeSpaceReply {
        trace.dockNotificationUptimes = notifications?.values ?? []
        return .init(id: request.id, state: state, detail: text, canSwitch: canSwitch && state != .outcomeUnknown, canMove: canMove,
              currentBefore: before?.currents, currentAfter: after?.currents,
              membershipBefore: oldMembership, membershipAfter: newMembership,
              issuedAtUptime: issuedAt, confirmedAtUptime: state == .confirmed ? ProcessInfo.processInfo.systemUptime : nil,
              submittedSteps: steps, switchTrace: request.action == .select ? trace : nil,
              originalWindow: state == .awaitingStep ? request.originalWindow : nil)
    }
    do {
        guard available else { throw ActionFailure("此系统构建尚不支持原生桌面动作。") }
        guard request.isFresh(at: ProcessInfo.processInfo.systemUptime) else { throw ActionFailure("桌面动作已过期。") }
        let start = try ActionInventory.read()
        before = start
        if request.action == .observeWindows {
            guard let probes = request.observations, request.window == nil, request.originalWindow == nil else {
                throw ActionFailure("窗口观察请求不完整。")
            }
            let tokens = try witnesses.observe(probes, inventory: start)
            return .init(id: request.id, state: .ready, detail: "已核对窗口身份。", canSwitch: canSwitch,
                         canMove: canMove, observedWindows: tokens)
        }
        if request.action == .probe { return reply(.ready, "已读取当前空间能力。") }
        let (display, from, to) = try start.route(request)
        var expected = start.currents
        var progress = from
        var witness: WindowWitness?
        var selectedWindow: SelectedWindowWitness?
        if request.action == .move {
            guard canMove, let window = request.window, let target = UInt64(request.target)
            else { throw ActionFailure("缺少窗口迁移权限或系统支持。") }
            let checked = try WindowWitness.read(window, display: display)
            witness = checked
            oldMembership = WindowWitness.membership(window.number)
            guard oldMembership == [request.source] else { throw ActionFailure("窗口的来源空间已改变。") }
            let live = try WindowWitness.read(window, display: display)
            guard checked.agreesBeforeDispatch(with: live), try ActionInventory.read() == start,
                  live.stillIdentical(),
                  WindowWitness.membership(window.number) == oldMembership
            else { throw ActionFailure("迁移前窗口或空间已改变。") }
            let submitted = ProcessInfo.processInfo.systemUptime
            guard request.isFresh(at: submitted) else { throw ActionFailure("迁移动作已过期。") }
            if from == to { after = start; newMembership = oldMembership; return reply(.confirmed, "窗口已在目标桌面。") }
            issued = NPRequestMove(window.number, target)
            if issued { issuedAt = submitted; steps = 1 }
        } else {
            guard canSwitch else { throw ActionFailure("缺少向系统请求桌面切换的权限。") }
            if let token = request.originalWindow {
                selectedWindow = try SelectedWindowWitness { try witnesses.selected(request, token: token) }
            } else {
                selectedWindow = try request.window.map { try SelectedWindowWitness($0, display: display, space: request.target) }
            }
            if from == to { after = start; return reply(.confirmed, "已在目标桌面。") }
            guard try ActionInventory.read() == start else { throw ActionFailure("切换前显示器或空间已改变。") }
            expected[UUID(uuidString: request.display)!.uuidString] = request.target
            guard abs(to - from) == 1 else { throw ActionFailure("只允许单次相邻切换。") }
            notifications = SpaceNotificationTimes()
            let permission = try authorize(reply(.awaitingStep, "等待确认当前选择。"))
            let now = ProcessInfo.processInfo.systemUptime
            guard permission.permits(request, after: 0, now: now), isBundledChild(),
                  try ActionInventory.read() == start else { throw ActionFailure("选择已取消或来源桌面已改变。") }
            try selectedWindow?.verify()
            trace.observations.append(.init(uptime: now, currents: start.currents,
                frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier))
            var dispatch = NPDockDispatch()
            guard NPSendAdjacentSwipe(to > from, display.number, &dispatch) else {
                throw ActionFailure("当前指针、显示器或系统版本无法接收桌面手势。")
            }
            issued = true
            steps = 1
            issuedAt = now
            trace.adapter = Int(dispatch.protocolVersion)
            trace.phasesMachTicks = [dispatch.phaseTimes.0, dispatch.phaseTimes.1, dispatch.phaseTimes.2]
            trace.progress = dispatch.signedProgress
            trace.endVelocity = dispatch.endVelocity
            trace.naturalScrolling = dispatch.natural
        }
        guard issued else { throw ActionFailure("系统动作未投递，请从目标屏幕的侧栏操作。") }
        let deadline = min(request.deadlineUptime, ProcessInfo.processInfo.systemUptime + (request.action == .select ? 2.8 : 1.8))
        var stableSince: TimeInterval?
        repeat {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.04))
            let view = try ActionInventory.read()
            after = view
            if let witness {
                let rebound = try WindowWitness.read(witness.identity, display: display)
                guard witness.sameWindowAndSiblings(as: rebound),
                      let membership = WindowWitness.membership(witness.identity.number),
                      try ActionInventory.read() == view else {
                    throw ActionFailure("提交后窗口、同应用其他窗口或空间已改变。")
                }
                newMembership = membership
            }
            let now = ProcessInfo.processInfo.systemUptime
            if witness != nil, now >= deadline { break }
            if request.action == .select {
                let owner = NSWorkspace.shared.frontmostApplication?.processIdentifier
                if trace.observations.last?.currents != view.currents || trace.observations.last?.frontPID != owner {
                    trace.observations.append(.init(uptime: now, currents: view.currents, frontPID: owner))
                }
                progress = try view.transition(from: start, request: request, previous: progress)
            } else if !view.agrees(with: start, expected: expected) {
                throw ActionFailure("迁移期间其他桌面或显示器发生改变。")
            }
            let reached = view.currents == expected && (witness == nil || newMembership == [request.target])
            if reached {
                if request.action == .select, request.window == nil, request.targetKind == .ordinary, trace.emptyGuard == nil {
                    trace.emptyGuard = try EmptyLandingGuard.protect(space: request.target)
                }
                // A window-follow reversal can occur about 400 ms after a transient landing.
                if let stableSince, now - stableSince >= (request.action == .select ? 0.85 : 0.16) {
                    if request.action == .select {
                        trace.observations.append(.init(uptime: now, currents: view.currents,
                            frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier))
                        if trace.emptyGuard == "windowless-activation-requested" && !NSRunningApplication.current.isActive {
                            throw ActionFailure("空桌面前台保护尚未确认。")
                        }
                    }
                    try selectedWindow?.verify()
                    return reply(.confirmed, "已由系统连续确认目标。")
                }
                if stableSince == nil { stableSince = now }
            } else { stableSince = nil }
        } while ProcessInfo.processInfo.systemUptime < deadline
        return reply(.outcomeUnknown, "动作已提交，系统未在期限内确认结果。")
    } catch {
        return reply(issued ? .outcomeUnknown : .failed, (error as? ActionFailure)?.text ?? "无法核验系统状态。")
    }
}

private func awaitStepPermission(_ reply: NativeSpaceReply) throws -> NativeSpaceStepPermission {
    do {
        return try StepHandshake.exchange(reply, input: .standardInput, output: .standardOutput)
    } catch {
        // A late fragment must never be parsed as a later command.
        exit(75)
    }
}

if CommandLine.arguments.dropFirst() == ["--self-check"] {
    print("NearpaneSpaceAction schema=2; no action issued")
} else if CommandLine.arguments.dropFirst() == ["--serve"], isBundledChild() {
    let supported = NPReadOnlySpacesOpen() == 1
    var consumed = Set<UUID>()
    let witnesses = SidebarWindowWitnesses()
    while let line = readLine(), isBundledChild() {
        guard line.utf8.count <= 16384,
              let request = try? JSONDecoder().decode(NativeSpaceCommand.self, from: Data(line.utf8))
        else { exit(65) }
        let result: NativeSpaceReply
        if (request.action == .select || request.action == .move) && (consumed.count >= 65536 || !consumed.insert(request.id).inserted) {
            result = .init(id: request.id, state: .failed, detail: "过期或重复的动作。", canSwitch: false, canMove: false)
        } else {
            result = autoreleasepool { run(request, available: supported, witnesses: witnesses, authorize: awaitStepPermission) }
        }
        guard let bytes = try? JSONEncoder().encode(result) else { exit(70) }
        FileHandle.standardOutput.write(bytes + Data([10]))
    }
} else { exit(64) }
