import AppKit
import CryptoKit
import Darwin
import NearpaneCore

struct OrdinaryWindowFailure: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
    init(_ reason: String) { self.reason = reason }
}

@MainActor private final class BoundaryAlerts {
    // One private channel serves the retained windows of one selected application.
    var listeners = [ManagedWindowID: @MainActor () -> Void]()

    func notify() {
        for wake in listeners.values { wake() }
    }
}

private actor OrdinaryWindowChannel {
    private let process: Process
    private let input, output, alertsInput: FileHandle

    init(alerts: BoundaryAlerts, previewWindow: UInt32? = nil) throws {
        let root = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let executable = root.appendingPathComponent("Contents/Helpers/NearpaneOrdinaryWindowController")
        guard executable.resolvingSymlinksInPath().path == executable.path,
              let expected = Bundle.main.object(forInfoDictionaryKey: "NearpaneOrdinaryWindowControllerSHA256") as? String,
              try SHA256.hash(data: Data(contentsOf: executable, options: .mappedIfSafe))
                .map({ String(format: "%02x", $0) }).joined() == expected
        else { throw OrdinaryWindowFailure("无法核验此版本的窗口控制助手。") }
        let process = Process(), commands = Pipe(), replies = Pipe(), signals = Pipe()
        // If the helper dies between isRunning and write(2), return EPIPE without
        // delivering SIGPIPE to the Host (which also owns the text and screenshot stores).
        guard fcntl(commands.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0
        else { throw OrdinaryWindowFailure("无法安全建立窗口控制通道。") }
        process.executableURL = executable
        if let previewWindow { process.arguments = ["--read-only-preview", String(previewWindow)] }
        process.standardInput = commands
        process.standardOutput = replies
        // Only the nonce-checked stdout RPC can issue or acknowledge an operation.
        // A dedicated notification pipe can lose wakeups; the periodic check still runs.
        let signalFD = signals.fileHandleForWriting.fileDescriptor
        guard fcntl(signalFD, F_SETFL, O_NONBLOCK) == 0 else {
            throw OrdinaryWindowFailure("无法建立逐窗事件通知通道。")
        }
        process.standardError = signals
        try process.run()
        commands.fileHandleForReading.closeFile()
        replies.fileHandleForWriting.closeFile()
        signals.fileHandleForWriting.closeFile()
        self.process = process
        input = commands.fileHandleForWriting
        output = replies.fileHandleForReading
        alertsInput = signals.fileHandleForReading
        alertsInput.readabilityHandler = { [weak alerts] handle in
            let bytes = handle.availableData
            if bytes.isEmpty { handle.readabilityHandler = nil; return }
            if bytes.contains(0x1E) { Task { @MainActor in alerts?.notify() } }
        }
    }

    nonisolated var pid: pid_t { process.processIdentifier }
    nonisolated var isRunning: Bool { process.isRunning }

    nonisolated func interrupt() {
        if process.isRunning { process.terminate() }
    }

    deinit {
        alertsInput.readabilityHandler = nil
        try? alertsInput.close()
        try? input.close()
        try? output.close()
    }

    func call(_ command: OrdinaryWindowRequest, permit: NativeSelectionPermit? = nil,
              timeout: TimeInterval = 8) throws -> OrdinaryWindowReply {
        guard process.isRunning else { throw OrdinaryWindowFailure("窗口助手已结束，原授权失效。") }
        let reply: OrdinaryWindowReply
        do {
            var bytes = try JSONEncoder().encode(command)
            bytes.append(10)
            try input.write(contentsOf: bytes)
            var nextStep = 0
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while true {
                var result = Data()
                while result.count <= 64_000 {
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
                    guard remaining > 0,
                          poll(&descriptor, 1, Int32(min(remaining * 1000, 8000))) > 0
                    else { throw OrdinaryWindowFailure("窗口助手超时或已停止，保留恢复记录。") }
                    // On Darwin FileHandle.read(upToCount:) waits for the count or EOF. This pipe
                    // carries many newline-delimited replies and intentionally stays open.
                    var buffer = [UInt8](repeating: 0, count: 8192)
                    let n = Darwin.read(output.fileDescriptor, &buffer, buffer.count)
                    guard n > 0 else { throw OrdinaryWindowFailure("窗口助手已结束，保留恢复记录。") }
                    result.append(contentsOf: buffer.prefix(n))
                    if result.last == 10 { break }
                }
                let message = try JSONDecoder().decode(OrdinaryWindowReply.self, from: result)
                guard message.nonce == command.nonce else { throw OrdinaryWindowFailure("收到过期的窗口操作回执。") }
                guard let step = message.focusStep else { reply = message; break }
                guard command.action == .focusCurrent, nextStep == step, step < 8, let permit else {
                    throw OrdinaryWindowFailure("窗口助手的焦点步骤无效。")
                }
                let decision = permit.permission(for: command.nonce, after: step)
                try input.write(contentsOf: JSONEncoder().encode(decision) + Data([10]))
                nextStep += 1
            }
        } catch {
            try? input.close()
            if process.isRunning { process.terminate() }
            throw error
        }
        if let error = reply.failure {
            if command.action == .list, reply.listAccessDenied == true { throw AdmissionReadFailure.permission }
            if command.action == .write, command.pairPlacement != nil {
                throw IncompletePairWrite(reason: error, steps: reply.steps ?? [])
            }
            throw OrdinaryWindowFailure(error)
        }
        return reply
    }
}

@MainActor final class OrdinaryWindowDirectory {
    private struct UnboundFocusWorker: Sendable {
        let channel: OrdinaryWindowChannel
        let alerts: BoundaryAlerts
        let hostImage, helperImage: OrdinaryProcessImage

        func belongsToCurrentInstall() -> Bool {
            channel.isRunning && (try? OrdinaryProcessImage.read(getpid())) == hostImage &&
                (try? OrdinaryProcessImage.read(channel.pid)) == helperImage
        }
    }

    private static let focusStandby = FocusWorkerStandby<UnboundFocusWorker>()

    private static func startUnboundFocusWorker() -> Task<UnboundFocusWorker, Error> {
        let alerts = BoundaryAlerts()
        return Task.detached(priority:.userInitiated) {
            try Task.checkCancellation()
            let host = try OrdinaryProcessImage.read(getpid())
            let channel = try OrdinaryWindowChannel(alerts:alerts)
            // This read-only readiness request has neither an owner nor a window.
            // Discard the permission value. The worker checks AX trust again when the real
            // click lists its owner and when the Host approves each individual write.
            let ready = try await channel.call(.init(.checkFocusPermission, pid:0, launch:0, bundle:""), timeout:1)
            try Task.checkCancellation()
            guard ready.focusPermission != nil, try OrdinaryProcessImage.read(getpid()) == host else {
                throw OrdinaryWindowFailure("窗口控制助手的安装代际已变化。")
            }
            return try UnboundFocusWorker(channel:channel, alerts:alerts, hostImage:host,
                                          helperImage:OrdinaryProcessImage.read(channel.pid))
        }
    }

    @discardableResult static func prepareSidebarFocus() -> Bool { focusStandby.prepare(startUnboundFocusWorker) }

    static func forSidebarFocus(_ app: AdmissionApplication) async throws -> OrdinaryWindowDirectory {
        let worker: UnboundFocusWorker
        do { worker = try await focusStandby.take(startUnboundFocusWorker) }
        catch is CancellationError { throw CancellationError() }
        catch { return try OrdinaryWindowDirectory(app) }
        // A short-lived empty process carries no target. If its code image was replaced,
        // discard it and run the ordinary signed startup for this selection.
        guard worker.belongsToCurrentInstall() else {
            worker.channel.interrupt()
            return try OrdinaryWindowDirectory(app)
        }
        return OrdinaryWindowDirectory(app, worker:worker)
    }

    /// Ask the signed process that actually selects windows. This channel never lists or binds a window.
    static func focusPermission(prompt: Bool) async -> Bool? {
        do {
            let alerts = BoundaryAlerts()
            let channel = try OrdinaryWindowChannel(alerts:alerts)
            let action: OrdinaryWindowRequest.Action = prompt ? .requestFocusPermission : .checkFocusPermission
            let response = try await channel.call(.init(action, pid:0, launch:0, bundle:""))
            if response.focusPermission != nil {
                // The settings probe already has a signed, nonce-checked empty channel. Only
                // its process is reusable; the original permission answer is returned to Settings.
                focusStandby.prepare {
                    Task {
                        try UnboundFocusWorker(channel:channel, alerts:alerts, hostImage:OrdinaryProcessImage.read(getpid()),
                                               helperImage:OrdinaryProcessImage.read(channel.pid))
                    }
                }
            }
            return response.focusPermission
        } catch { return nil }
    }

    let app: AdmissionApplication
    private let channel: OrdinaryWindowChannel
    private let alerts: BoundaryAlerts
    private(set) var handles = [UUID: OrdinaryWindowAX]()

    private init(_ app: AdmissionApplication, worker: UnboundFocusWorker) {
        self.app = app
        alerts = worker.alerts
        channel = worker.channel
    }

    init(_ app: AdmissionApplication, previewWindow: UInt32? = nil) throws {
        self.app = app
        let alerts = BoundaryAlerts()
        self.alerts = alerts
        channel = try OrdinaryWindowChannel(alerts: alerts, previewWindow: previewWindow)
    }

    func choices(initial: Bool) async throws -> [AdmissionWindowChoice] {
        let action: OrdinaryWindowRequest.Action = initial ? .list : .refresh
        let result: OrdinaryWindowReply
        do {
            result = try await channel.call(.init(action, pid: app.pid, launch: app.launch, bundle: app.bundle))
            if initial { WindowOverviewAccess.shared.recordWorkerFocus(true) }
        } catch AdmissionReadFailure.permission {
            WindowOverviewAccess.shared.recordWorkerFocus(false)
            throw AdmissionReadFailure.permission
        }
        guard let choices = result.choices, choices.count <= 64 else { throw OrdinaryWindowFailure("窗口清单不完整。") }
        var next = [UUID: OrdinaryWindowAX]()
        let rows = try choices.enumerated().map { index, id -> AdmissionWindowChoice in
            guard let id else { return .init(id: UUID(), number: nil, index: index + 1) }
            guard id.pid == app.pid, id.launch == app.launch, id.number != 0, next[id.element] == nil
            else { throw OrdinaryWindowFailure("无法核对窗口清单身份。") }
            next[id.element] = handles[id.element] ?? OrdinaryWindowAX(id: id, application: app, channel: channel, alerts: alerts)
            return .init(id: id.element, number: id.number, index: index + 1)
        }
        handles = next
        return rows
    }
}

@MainActor final class OrdinaryWindowAX {
    let id: ManagedWindowID, bundle: String, applicationName: String
    private let channel: OrdinaryWindowChannel
    private let alerts: BoundaryAlerts
    private var closed = false
    private(set) var lastWriteSteps = [OrdinaryWindowStep]()

    fileprivate init(id: ManagedWindowID, application: AdmissionApplication, channel: OrdinaryWindowChannel,
                     alerts: BoundaryAlerts) {
        self.id = id
        self.bundle = application.bundle
        self.applicationName = application.name
        self.channel = channel
        self.alerts = alerts
    }

    func onBoundaryChange(_ wake: (@MainActor () -> Void)?) { alerts.listeners[id] = wake }

    deinit {
        let command = OrdinaryWindowRequest(.release, pid: id.pid, launch: id.launch, bundle: bundle, id: id)
        Task { [channel] in _ = try? await channel.call(command) }
    }

    func setCreationWatch(_ token: UUID, enabled: Bool) async throws {
        guard !closed else { throw OrdinaryRefusal.lost }
        _ = try await channel.call(.init(enabled ? .watchCreated : .endCreated, pid: id.pid, launch: id.launch,
                                         bundle: bundle, id: id, creationGrant: token))
    }

    func nextCreatedWindow(_ token: UUID) async throws -> CreatedWindowResult {
        guard !closed else { throw OrdinaryRefusal.lost }
        let reply = try await channel.call(.init(.takeCreated, pid: id.pid, launch: id.launch, bundle: bundle,
                                                 id: id, creationGrant: token))
        guard !closed else { throw OrdinaryRefusal.lost }
        if let reason = reply.skippedCreated { return .skipped(reason) }
        guard let created = reply.created else { return .none }
        guard created.pid == id.pid, created.launch == id.launch, created.number != id.number,
              created.number != 0 else { throw OrdinaryRefusal.ambiguous }
        let app = AdmissionApplication(pid: id.pid, launch: id.launch, bundle: bundle, name: applicationName)
        return .window(OrdinaryWindowAX(id: created, application: app, channel: channel, alerts: alerts))
    }

    private(set) var desktopBinding: OrdinaryDesktopIdentity?
    func bindDesktop(_ value: OrdinaryDesktopIdentity) throws {
        guard desktopBinding == nil || desktopBinding == value else { throw OrdinaryRefusal.scope }
        desktopBinding = value
    }
    func prepare() async throws -> AdmissionPair { try await sample(.prepare) }
    func observeBoundary(expected: SurfaceRect) async throws -> OrdinaryBoundaryObservation {
        guard !closed else { throw OrdinaryRefusal.lost }
        let reply = try await channel.call(.init(.observeBoundary, pid: id.pid, launch: id.launch, bundle: bundle,
                                                 id: id, expected: expected))
        guard !closed else { throw OrdinaryRefusal.lost }
        if let closure = reply.closure, closure.id == id, reply.boundary == nil { throw closure }
        guard let read = reply.boundary, read.previous == expected else { throw OrdinaryRefusal.stale }
        return read
    }
    func acknowledgeBoundary(_ observation: OrdinaryBoundaryObservation) async throws -> AdmissionPair {
        guard let frame = observation.pair?.second.cgFrame, let revision = observation.revision, observation.settled else {
            throw OrdinaryRefusal.stale
        }
        return try await sample(.acknowledgeBoundary, from: observation.previous, to: frame, revision: revision)
    }
    func stillSelected() async -> Bool {
        guard !closed, let result = try? await channel.call(.init(.refresh, pid: id.pid, launch: id.launch, bundle: bundle)),
              let choices = result.choices, choices.count <= 64 else { return false }
        // Refresh keeps the original element UUID only for a unique live CFEqual AX object.
        return !closed && choices.compactMap { $0 }.filter { $0.number == id.number } == [id]
    }

    func focusCurrent(frame: SurfaceRect, display: String, deadline: TimeInterval, space: String?, permit: NativeSelectionPermit,
                      timing: WindowFocusTiming? = nil) async throws {
        guard !closed else { throw OrdinaryWindowFailure("窗口已关闭。") }
        _ = try await channel.call(.init(.focusCurrent, pid: id.pid, launch: id.launch, bundle: bundle, id: id,
                                         expected: frame, focusDisplay: display, focusDeadline: deadline, focusSpace: space,
                                         focusTimingID: timing?.id), permit: permit)
    }

    func verify(expected: SurfaceRect) async throws -> AdmissionPair { try await sample(.verify, from: expected) }
    func write(from: SurfaceRect, to: SurfaceRect, placement: OrdinaryWindowPairPlacement) async throws -> AdmissionPair {
        try await sample(.write, from: from, to: to, placement: placement)
    }

    func write(from: SurfaceRect, to: SurfaceRect) async throws -> AdmissionPair {
        try await sample(.write, from: from, to: to)
    }

    private func sample(_ action: OrdinaryWindowRequest.Action, from: SurfaceRect? = nil, to: SurfaceRect? = nil, revision: UUID? = nil,
                        placement: OrdinaryWindowPairPlacement? = nil) async throws -> AdmissionPair {
        guard !closed else { throw OrdinaryWindowFailure("该窗口授权已结束。") }
        let response = try await channel.call(.init(action, pid: id.pid, launch: id.launch, bundle: bundle,
                                                    id: id, expected: from, destination: to, boundaryRevision: revision,
                                                    desktop: desktopBinding, pairPlacement: placement))
        if !closed, action == .verify, let witness = response.closure, witness.id == id, response.pair == nil {
            throw witness
        }
        guard let pair = response.pair, pair.first.id == id, pair.second.id == id,
              !closed else { throw OrdinaryWindowFailure("所选窗口身份已失效。") }
        if action == .write { lastWriteSteps = response.steps ?? [] }
        return pair
    }

    func invalidate() {
        closed = true
        channel.interrupt()
    }

}
