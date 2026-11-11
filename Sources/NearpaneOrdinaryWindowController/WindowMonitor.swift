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
    private var expectedFrame: SurfaceRect?, waitingFor: String?, notificationCount = 0

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
        guard let waitingFor, event == waitingFor, notificationCount == 0 else {
            failure = "发生未经本次操作确认的窗口变化，已暂停并保留恢复记录。"; return
        }
        notificationCount += 1
    }

    private func check() throws {
        if let failure { throw Refusal(failure) }
        try require(getppid() == parent, "窗口管理会话已结束。")
    }

    private func read() throws -> AdmissionSample {
        try check()
        var sample = try observation(owner,id,bundle,element)
        sample.liveObservation = incarnation
        sample.recoveryVerified = true
        if let baseline {
            try require(sample.display == baseline.display, "窗口所属显示器已变化。")
        }
        if sample.minimum == nil, let size = baseline?.axFrame ?? sample.axFrame {
            sample.minimum = .init(width:size.width,height:size.height)
            sample.usesWitnessedSize = true
        }
        return sample
    }

    private func pair(expected: SurfaceRect?) throws -> AdmissionPair {
        drainWindowEvents(0.004)
        let a = try read()
        drainWindowEvents(0.095)
        let b = try read()
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
            baseline = p.second
            expectedFrame = p.second.cgFrame
        }
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
        func absence() throws -> TimeInterval {
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
            try require(NPWindowNumberConfirmedAbsent(id.number) == 1, "WindowServer 尚未确认原窗口编号消失。")
            try checkOwner(owner, pid: id.pid, launch: id.launch, bundle: bundle)
            return ProcessInfo.processInfo.systemUptime
        }
        let first = try absence()
        drainWindowEvents(0.095)
        let second = try absence()
        certifiedClosed = true
        return .init(id: id, destroyed: notificationTime ?? first, firstAbsent: first, secondAbsent: second, evidence: evidence)
    }

    func write(from: SurfaceRect, to: SurfaceRect) throws -> (AdmissionPair,[OrdinaryWindowStep]) {
        let before = try verify(from)
        guard let bounds = before.second.minimum, let display = before.second.display,
              to.geometry.isValid, to.width >= bounds.width, to.height >= bounds.height,
              try displayID(to) == display else { throw Refusal("目标超出可证实的窗口尺寸或显示区域。") }
        if from == to { return (before,[]) }
        let focus = try FrontFocus()
        let narrow = SurfaceRect(x:from.x,y:from.y,width:min(from.width,to.width),height:min(from.height,to.height))
        let positioned = SurfaceRect(x:to.x,y:to.y,width:narrow.width,height:narrow.height)
        var prior = from, receipts = [OrdinaryWindowStep]()
        do {
            for next in [narrow, positioned, to] where next != prior {
                try focus.check()
                receipts.append(try step(from:prior,to:next,focus:focus))
                prior = next
            }
            let confirmed = try pair(expected:to)
            try focus.check()
            expectedFrame = to
            return (confirmed,receipts)
        } catch {
            failure = (error as? Refusal)?.message ?? "未能确认窗口操作，已暂停。"
            throw error
        }
    }

    private func step(from: SurfaceRect, to: SurfaceRect, focus: FrontFocus) throws -> OrdinaryWindowStep {
        drainWindowEvents(0.006)
        let pre = try read()
        try require(pre.cgFrame == from && pre.axFrame == from && pre.display == (try displayID(to)), "写入前窗口几何或身份变化。")
        let moving = from.x != to.x || from.y != to.y
        let event = moving ? kAXWindowMovedNotification : kAXWindowResizedNotification
        let key = moving ? kAXPositionAttribute : kAXSizeAttribute
        var p = CGPoint(x:to.x,y:to.y), size = CGSize(width:to.width,height:to.height)
        guard let value = moving ? AXValueCreate(.cgPoint,&p) : AXValueCreate(.cgSize,&size) else { throw Refusal("无法构造 AX 几何。") }
        try check()
        try focus.check()
        // AppKit posts the completed move/resize notification at the end of a drag.
        // A held button means an in-progress user gesture may still have no notification.
        for button in [CGMouseButton.left, .right, .center] {
            try require(!CGEventSource.buttonState(.combinedSessionState, button: button),
                        "鼠标操作尚未结束，暂不调整窗口。")
        }
        waitingFor = event; notificationCount = 0
        defer { waitingFor = nil }
        let rc = AXUIElementSetAttributeValue(element,key as CFString,value)
        try require(rc == .success, "AX 几何操作被拒绝（" + String(rc.rawValue) + "）。")
        let end = ProcessInfo.processInfo.systemUptime + 0.8
        repeat {
            drainWindowEvents(0.025)
            try check()
            if let s = try? read(), let ax = s.axFrame, let cg = s.cgFrame {
                try require(cg == from || cg == to, "写入期间出现其他窗口几何。")
                if ax == to && cg == to && notificationCount == 1 {
                    try focus.check()
                    return OrdinaryWindowStep(from:from,to:to,ax:ax,cg:cg,notification:event,uptime:s.uptime)
                }
            }
        } while ProcessInfo.processInfo.systemUptime < end
        throw Refusal("系统未在时限内共同确认 AX、CG 和对应窗口事件（" + event + "，通知 " + String(notificationCount) + "）。")
    }
}
