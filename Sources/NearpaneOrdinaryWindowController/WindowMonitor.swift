import AppKit
import ApplicationServices
import CReadOnlySpaces
import NearpaneCore

/// All registrations and callbacks live on the executable's one owning thread/run loop.
func drainWindowEvents(_ seconds: Double) {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    repeat {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        if remaining <= 0 { break }
        CFRunLoopRunInMode(.defaultMode, remaining, false)
    } while ProcessInfo.processInfo.systemUptime < deadline
}

/// WindowServer can draw a closing animation after the original AX object is destroyed.
/// Wait once for that transition, then confirm absence with two full AX/CG reads.
func confirmedRemovalTimes(now: () -> TimeInterval, wait: (Double) -> Void,
                           readAbsent: () throws -> Bool) throws -> (TimeInterval, TimeInterval) {
    let deadline = now() + 0.8
    while try !readAbsent() {
        let remaining = deadline - now()
        try require(remaining > 0, "关闭等待结束后 WindowServer 仍保留原窗口编号。")
        wait(min(remaining, 0.08))
    }
    let first = now()
    wait(0.095)
    try require(try readAbsent(), "第二次读回时原窗口编号重新出现。")
    return (first, now())
}

final class WindowMonitor {
    let id: ManagedWindowID, bundle: String, element: AXUIElement
    private let owner: OrdinaryOwnerIdentity
    let parent: pid_t
    private var observer: AXObserver?, failure: String?
    private var destroyedAt: TimeInterval?
    private var certifiedClosed = false
    var canListAgain: Bool { destroyedAt == nil && !certifiedClosed }
    var hasObserver: Bool { observer != nil }
    private let incarnation = UUID()
    private var baseline: AdmissionSample?
    private var witnessedSizes = OrdinaryWitnessedSizes()
    private var lastPublishedMinimum: SurfaceRect?
    private var expectedFrame: SurfaceRect?, waitingFor: String?, notificationCount = 0
    private var displayWitness: BoundaryDisplayWitness?
    private var changes = BoundaryChangeTracker()
    private var acknowledgedMotion = false
    private var buttonDown: Bool {
        [CGMouseButton.left, .right, .center].contains { CGEventSource.buttonState(.combinedSessionState, button: $0) }
    }

    init(id: ManagedWindowID, bundle: String, element: AXUIElement, parent: pid_t, owner: OrdinaryOwnerIdentity) {
        self.owner = owner
        self.id = id; self.bundle = bundle; self.element = element; self.parent = parent
    }

    func stop() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(),AXObserverGetRunLoopSource(observer),.defaultMode)
        }
        observer = nil
        failure = "窗口观察已结束。"
    }

    private func start() throws {
        if observer != nil { return }
        var result: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, context in
            guard let context else { return }
            let owner = Unmanaged<WindowMonitor>.fromOpaque(context).takeUnretainedValue()
            owner.receive(element, notification as String)
        }
        try require(AXObserverCreate(id.pid,callback,&result) == .success, "系统无法建立逐窗事件观察。")
        guard let result else { throw Refusal("系统未返回逐窗观察器。") }
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXWindowMovedNotification, kAXWindowResizedNotification, kAXUIElementDestroyedNotification] {
            try require(AXObserverAddNotification(result,element,name as CFString,context) == .success,
                        "窗口不支持所需系统通知（" + name + "）。")
        }
        observer = result
        CFRunLoopAddSource(CFRunLoopGetCurrent(),AXObserverGetRunLoopSource(result),.defaultMode)
    }

    private func receive(_ source: AXUIElement, _ event: String) {
        guard CFEqual(source,element) else {
            failure = "原窗口已经关闭或系统观察对象发生变化。"; return
        }
        if event == kAXUIElementDestroyedNotification {
            if failure == nil, waitingFor == nil { destroyedAt = ProcessInfo.processInfo.systemUptime }
            failure = "原窗口收到销毁通知。"
            return
        }
        if waitingFor == nil, event == kAXWindowMovedNotification || event == kAXWindowResizedNotification {
            let firstNotice = !changes.pending
            changes.received(at: ProcessInfo.processInfo.systemUptime)
            if firstNotice {
                // A nonblocking, coalesced wakeup to the verified parent. No window or
                // input data is sent; a missed signal falls back to its regular poll.
                var signal: UInt8 = 0x1E
                _ = Darwin.write(STDERR_FILENO, &signal, 1)
            }
            return
        }
        guard let waitingFor, event == waitingFor, notificationCount == 0 else {
            failure = "发生未经本次操作确认的窗口变化，已暂停并保留恢复记录。"; return
        }
        notificationCount += 1
    }

    private func check() throws {
        if let failure { throw Refusal(failure) }
        try require(getppid() == parent, "窗口管理会话已结束。")
    }

    private func read(boundary: Bool = false) throws -> AdmissionSample {
        try check()
        try require(boundary || !changes.pending, "有待核对的外部窗口变化。")
        var sample = try observation(owner,id,bundle,element, boundaryDisplay: boundary || acknowledgedMotion ? displayWitness : nil)
        sample.liveObservation = incarnation
        sample.recoveryVerified = true
        if let baseline {
            try require(sample.display == baseline.display, "窗口所属显示器已变化。")
        }
        try checkDesktop(sample.display)
        if let published = sample.minimum { lastPublishedMinimum = published }
        else if let frame = sample.axFrame {
            sample.minimum = witnessedSizes.minimum(at: frame)
            sample.usesWitnessedSize = true
        }
        return sample
    }

    private func pair(expected: SurfaceRect?, boundary: Bool = false) throws -> AdmissionPair {
        drainWindowEvents(0.004)
        let a = try read(boundary: boundary)
        drainWindowEvents(0.095)
        let b = try read(boundary: boundary)
        try require(a.axFrame == b.axFrame && a.cgFrame == b.cgFrame && a.display == b.display &&
                    a.minimum == b.minimum && a.stageManager == b.stageManager &&
                    (expected == nil || expected == b.cgFrame), "两次独立观测未确认同一窗口和预期几何。")
        return .init(first:a,second:b)
    }

    func prepare() throws -> AdmissionPair {
        try check()
        try start()
        let p = try pair(expected:expectedFrame)
        if baseline == nil {
            guard let display = p.second.display else { throw Refusal("无法核对原显示器。") }
            displayWitness = try boundaryDisplayWitness(display)
            baseline = p.second
            witnessedSizes.original = p.second.axFrame
            expectedFrame = p.second.cgFrame
        }
        return p
    }

    func observeBoundary(_ frame: SurfaceRect) throws -> OrdinaryBoundaryObservation {
        try require(baseline != nil && expectedFrame == frame && displayWitness != nil, "窗口边界基线已失效。")
        try check()
        drainWindowEvents(0.004)
        func waiting() -> OrdinaryBoundaryObservation {
            .init(pair: nil, previous: frame, revision: changes.revision, settled: false)
        }
        if buttonDown { return waiting() }
        let revision = changes.revision
        guard revision == nil || changes.isSettled(at: ProcessInfo.processInfo.systemUptime, buttonDown: buttonDown) else { return waiting() }
        let p: AdmissionPair
        do { p = try pair(expected: revision == nil ? frame : nil, boundary: true) }
        catch {
            if failure == nil && (changes.revision != revision || buttonDown) { return waiting() }
            throw error
        }
        if changes.revision != revision || buttonDown { return waiting() }
        guard revision != nil else { return .init(pair: p, previous: frame, revision: nil, settled: true) }
        guard let actual = p.second.cgFrame else { throw Refusal("当前窗口位置无法确认。") }
        let ticket = try changes.offer(actual, at: ProcessInfo.processInfo.systemUptime, buttonDown: buttonDown)
        return .init(pair: p, previous: frame, revision: ticket, settled: true)
    }

    func acknowledgeBoundary(from previous: SurfaceRect, current: SurfaceRect, revision: UUID) throws -> AdmissionPair {
        try require(baseline != nil && expectedFrame == previous && displayWitness != nil, "边界观测的原窗口已变化。")
        try changes.validate(revision, frame: current, at: ProcessInfo.processInfo.systemUptime, buttonDown: buttonDown)
        let p = try pair(expected: current, boundary: true)
        try changes.consume(revision, frame: current, at: ProcessInfo.processInfo.systemUptime, buttonDown: buttonDown)
        expectedFrame = current
        acknowledgedMotion = true
        return p
    }

    func verify(_ frame: SurfaceRect) throws -> AdmissionPair {
        try require(baseline != nil && expectedFrame == frame, "窗口事务与观察器基线不符。")
        do { return try pair(expected:frame) }
        catch { failure = (error as? Refusal)?.message ?? "窗口状态无法核对。"; throw error }
    }

    func closure(expected: SurfaceRect) throws -> OrdinaryWindowClosure {
        guard hasObserver, baseline != nil, expectedFrame == expected, waitingFor == nil,
              getppid() == parent else { throw Refusal("未取得原窗口的连续关闭见证。") }
        let notificationTime = destroyedAt
        let evidence: OrdinaryWindowClosure.Evidence = notificationTime == nil ? .invalidAXElement : .notification
        func absent() throws -> Bool {
            try checkOwner(owner, pid: id.pid, launch: id.launch, bundle: bundle)
            if evidence == .invalidAXElement {
                // A timeout, lost permission, or an empty AXWindows list is not invalidation.
                var role: CFTypeRef?
                let result = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
                try require(result == .invalidUIElement,
                            "未见原窗口销毁通知，原 AX 对象也未证实失效（\(result.rawValue)）。")
            }
            let current = try windows(id.pid)
            for candidate in current {
                guard !CFEqual(candidate, element), let candidateNumber = number(candidate),
                      candidateNumber != id.number else { throw Refusal("原窗口或编号的归属仍不明确。") }
            }
            let presence = NPReadWindowNumberPresence(id.number)
            try require(presence >= 0, "无法读取 WindowServer 中原窗口编号的状态。")
            try checkOwner(owner, pid: id.pid, launch: id.launch, bundle: bundle)
            return presence == 0
        }
        let (first, second) = try confirmedRemovalTimes(now: { ProcessInfo.processInfo.systemUptime },
                                                        wait: drainWindowEvents, readAbsent: absent)
        certifiedClosed = true
        return .init(id: id, destroyed: notificationTime ?? first, firstAbsent: first, secondAbsent: second, evidence: evidence)
    }

    private(set) var desktop: OrdinaryDesktopIdentity?

    func bindDesktop(_ value: OrdinaryDesktopIdentity) throws {
        try require(desktop == value || (desktop == nil && !hasObserver), "窗口授权所属桌面已变化。")
        try require(OrdinaryDesktopMembership.contains(id.number, display: value.display, record: value.record, uuid: value.uuid),
                    "未确认窗口唯一属于本屏当前的普通桌面。")
        desktop = value
    }

    private func checkDesktop(_ display: String?) throws {
        if let desktop {
            try require(display == desktop.display && OrdinaryDesktopMembership.contains(id.number,
                display: desktop.display, record: desktop.record, uuid: desktop.uuid), "窗口或显示器已离开获准桌面。")
        }
    }

    func write(from: SurfaceRect, to: SurfaceRect, placement: OrdinaryWindowPairPlacement?, retainedPeer: AXUIElement?,
               confirmedStep: (OrdinaryWindowStep) -> Void) throws -> AdmissionPair {
        let before = try verify(from)
        try checkDesktop(before.second.display)
        guard let floor = before.second.minimum, let display = before.second.display, to.geometry.isValid,
              try displayID(to) == display else { throw Refusal("目标超出可证实的窗口尺寸或显示区域。") }

        let fence: PairPlacementFence?
        let route: [SurfaceRect]
        if let placement {
            try require((desktop == nil || desktop == placement.desktop) && display == placement.desktop.display,
                        "本次双窗操作与原窗口或显示器授权不符。")
            let scope = try PairPlacementFence(placement, member: id, destination: to, retainedPeer: retainedPeer)
            try scope.check(memberFrame: from, memberElement: element)
            try checkExplicitMinimum(to)
            fence = scope
            route = PairPlacementGeometry.steps(from: from, to: to)
        } else {
            let usingWitness = before.first.usesWitnessedSize == true && before.second.usesWitnessedSize == true
            let fits = usingWitness ? witnessedSizes.allowsOrdinary(to, currentFloor: floor) : to.width >= floor.width && to.height >= floor.height
            try require(fits, "目标超出可证实的窗口尺寸。")
            if usingWitness, witnessedSizes.latestPair != nil, let known = lastPublishedMinimum {
                try require(to.width >= known.width && to.height >= known.height, "目标小于应用已公布的最小尺寸。")
            }
            fence = nil
            if usingWitness && witnessedSizes.latestPair != nil {
                // Returning from a narrower, taller size must not try a narrow-and-short
                // combination that neither of the two actual size witnesses established.
                route = PairPlacementGeometry.steps(from: from, to: to)
            } else {
                let narrow = SurfaceRect(x:from.x,y:from.y,width:min(from.width,to.width),height:min(from.height,to.height))
                let positioned = SurfaceRect(x:to.x,y:to.y,width:narrow.width,height:narrow.height)
                route = [narrow, positioned, to]
            }
        }
        if from == to { return fence == nil ? before : recordPairSize(before, frame: to) }
        let focus = try FrontFocus()
        if acknowledgedMotion, let witness = displayWitness {
            for step in route { _ = try boundaryDisplayID(step, witness: witness) }
        }
        var prior = from
        do {
            for next in route where next != prior {
                try focus.check()
                confirmedStep(try step(from: prior, to: next, focus: focus, fence: fence, final: to))
                prior = next
            }
            let confirmed = try pair(expected:to)
            try checkDesktop(confirmed.second.display)
            try fence?.check(memberFrame: to, memberElement: element)
            try focus.check()
            expectedFrame = to
            acknowledgedMotion = false
            return fence == nil ? confirmed : recordPairSize(confirmed, frame: to)
        } catch {
            failure = (error as? Refusal)?.message ?? "未能确认窗口操作，已暂停。"
            throw error
        }
    }

    // Both AX/CG samples and any submitted primitives confirmed this exact size.
    private func recordPairSize(_ pair: AdmissionPair, frame: SurfaceRect) -> AdmissionPair {
        witnessedSizes.confirmed(frame)
        func measured(_ sample: AdmissionSample) -> AdmissionSample {
            var result = sample
            if sample.usesWitnessedSize == true { result.minimum = witnessedSizes.minimum(at: frame) }
            return result
        }
        return .init(first: measured(pair.first), second: measured(pair.second))
    }

    private func checkExplicitMinimum(_ target: SurfaceRect) throws {
        let current = OrdinaryMinimumEvidence.read(element)
        if case .published(let size) = current { lastPublishedMinimum = .init(width: size.width, height: size.height) }
        try require(current.permits(target, lastPublished: lastPublishedMinimum),
                    "无法排除真实最小尺寸限制，本次双窗目标未获准。")
    }

    private func step(from: SurfaceRect, to: SurfaceRect, focus: FrontFocus, fence: PairPlacementFence?,
                      final: SurfaceRect) throws -> OrdinaryWindowStep {
        drainWindowEvents(0.006)
        let pre = try read()
        let targetDisplay = try acknowledgedMotion ? displayWitness.map { try boundaryDisplayID(to, witness: $0) } : displayID(to)
        try require(pre.cgFrame == from && pre.axFrame == from && pre.display == targetDisplay, "写入前窗口几何或身份变化。")
        let moving = from.x != to.x || from.y != to.y
        let event = moving ? kAXWindowMovedNotification : kAXWindowResizedNotification
        let key = moving ? kAXPositionAttribute : kAXSizeAttribute
        var p = CGPoint(x:to.x,y:to.y), size = CGSize(width:to.width,height:to.height)
        guard let value = moving ? AXValueCreate(.cgPoint,&p) : AXValueCreate(.cgSize,&size) else { throw Refusal("无法构造 AX 几何。") }
        try checkDesktop(pre.display)
        if let fence {
            try checkExplicitMinimum(final)
            try fence.check(memberFrame: from, memberElement: element)
        }
        try check()
        try focus.check()
        // A held button can precede the target's completed drag notification.
        try require(!buttonDown, "鼠标操作尚未结束，暂不调整窗口。")
        try fence?.checkCurrentSpace()
        waitingFor = event; notificationCount = 0
        defer { waitingFor = nil }
        let rc = AXUIElementSetAttributeValue(element,key as CFString,value)
        if fence != nil && rc != .success {
            let outcome: String
            switch rc {
            case .illegalArgument, .attributeUnsupported, .apiDisabled, .invalidUIElement, .notImplemented:
                outcome = "AX 拒绝了操作"
            default:
                outcome = "AX 未确认操作结果"
            }
            throw Refusal(outcome + "（" + key + "，" + String(rc.rawValue) + "）。已保留恢复记录。")
        }
        try require(rc == .success, "AX 几何操作被拒绝（" + String(rc.rawValue) + "）。")
        let end = ProcessInfo.processInfo.systemUptime + 0.8
        repeat {
            drainWindowEvents(0.025)
            try check()
            if let s = try? read(), let ax = s.axFrame, let cg = s.cgFrame {
                switch OrdinaryGeometryReadback.assess(from: from, to: to, ax: ax, cg: cg, notifications: notificationCount) {
                case .pending: break
                case .unexpected:
                    if fence != nil {
                        throw Refusal("AX 已接受 " + key + "，实际 AX/CG 几何为 " +
                                      "(\(cg.x), \(cg.y), \(cg.width), \(cg.height))，与目标不符。已停止并保留恢复记录。")
                    }
                    throw Refusal("写入期间出现其他窗口几何。")
                case .confirmed:
                    try fence?.check(memberFrame: to, memberElement: element)
                    try focus.check()
                    return OrdinaryWindowStep(from: from, to: to, ax: ax, cg: cg, notification: event, uptime: s.uptime)
                }
            }
        } while ProcessInfo.processInfo.systemUptime < end
        throw Refusal("系统未在时限内共同确认 AX、CG 和对应窗口事件（" + event + "，通知 " + String(notificationCount) + "）。")
    }
}
