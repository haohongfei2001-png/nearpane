import AppKit
import CryptoKit
import Darwin
import NearpaneCore

struct AdmissionApplication: Identifiable, Equatable {
    let pid: Int32, launch: UInt64, bundle: String, name: String
    var id: Int32 { pid }
}
struct AdmissionWindowChoice: Identifiable, Equatable {
    let id: UUID, number: UInt32?, index: Int
}
private enum AdmissionReadFailure: LocalizedError {
    case changed, permission, unknown, unavailable
    var errorDescription: String? {
        switch self {
        case .changed: "进程或所选窗口已变化，请重新选择。"
        case .permission: "当前辅助功能权限不足，无法读取所选应用的窗口。"
        case .unknown: "系统未提供可唯一核对的窗口编号，此窗口暂不可管理。"
        case .unavailable: "未取得完整的只读观测，请检查应用状态及现有辅助功能权限。"
        }
    }
}

/// Every entry point follows a user selection. Nothing here can dispatch a management action.
@MainActor final class WindowAdmissionReader {
    private let root: URL, fixtureOnly: Bool
    private var listed = [Int32:(AdmissionApplication,[AdmissionWindowChoice])]()
    init(support: URL, fixtureOnly: Bool) {
        self.root = support.appendingPathComponent("WorkRect")
        self.fixtureOnly = fixtureOnly
    }
    private func fixture(_ app: AdmissionApplication) -> AdmissionFixture? {
        guard app.bundle == AdmissionFixture.bundle, let f = AdmissionFixture.read(root),
              f.owner.owner.pid == app.pid, f.owner.owner.start == app.launch else { return nil }
        return f
    }
    func applications() -> [AdmissionApplication] {
        listed.removeAll()
        var result = [AdmissionApplication]()
        if let f = AdmissionFixture.read(root) {
            result.append(.init(pid: f.owner.owner.pid, launch: f.owner.owner.start, bundle: AdmissionFixture.bundle, name: "随包兼容应用"))
        }
        guard !fixtureOnly else { return result }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !app.isTerminated {
            guard app.processIdentifier != getpid(), let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier,
                  id != AdmissionFixture.bundle, !id.hasPrefix("org.nearpane."), let b = AdmissionBirth.read(app.processIdentifier) else { continue }
            result.append(.init(pid: b.pid, launch: b.start, bundle: id, name: app.localizedName ?? id))
        }
        return result.sorted { ($0.name,$0.pid) < ($1.name,$1.pid) }
    }
    private func check(_ app: AdmissionApplication) throws -> AdmissionFixture? {
        if app.bundle == AdmissionFixture.bundle {
            guard let f = fixture(app) else { throw AdmissionReadFailure.changed }
            return f
        }
        guard !fixtureOnly, app.pid != getpid(), AdmissionBirth.read(app.pid)?.start == app.launch,
              let running = NSRunningApplication(processIdentifier: app.pid), running.activationPolicy == .regular,
              running.bundleIdentifier == app.bundle, !running.isTerminated else { throw AdmissionReadFailure.changed }
        return nil
    }
    func windows(_ app: AdmissionApplication) async throws -> [AdmissionWindowChoice] {
        listed.removeValue(forKey: app.pid)
        let choices: [AdmissionWindowChoice]
        if let fixture = try check(app) {
            choices = fixture.owner.members.map { .init(id: $0.id.element, number: $0.id.number, index: $0.index) }
        } else {
            let reply = try await read(app, targets: [])
            guard reply.permitted else { throw AdmissionReadFailure.permission }
            let duplicates = Dictionary(grouping: reply.numbers.compactMap { $0 }, by: { $0 }).filter { $0.value.count > 1 }
            choices = reply.numbers.enumerated().map { offset, n in
                .init(id: UUID(), number: n.flatMap { duplicates[$0] == nil ? $0 : nil }, index: offset + 1)
            }
            _ = try check(app)
        }
        listed[app.pid] = (app,choices)
        return choices
    }
    func inspect(_ app: AdmissionApplication, selected: [AdmissionWindowChoice]) async throws -> [AdmissionPair] {
        guard !selected.isEmpty, Set(selected.map(\.id)).count == selected.count,
              let (prev,rows) = listed[app.pid], prev == app, selected.allSatisfy(rows.contains) else { throw AdmissionReadFailure.changed }
        let before = try check(app)
        let targets = try selected.map { w -> AdmissionReadRequest.Target in
            guard let n = w.number else { throw AdmissionReadFailure.unknown }
            guard let before else { return .init(number:n) }
            guard let m = before.owner.members.first(where: { $0.id.element == w.id && $0.id.number == n }) else { throw AdmissionReadFailure.changed }
            return .init(number:n,registeredIdentifier:m.identifier)
        }
        let reply = try await read(app, targets: targets)
        let after = try check(app)
        guard let before, let after else { return reply.pairs }
        guard before.owner.owner == after.owner.owner, before.run.session == after.run.session,
              before.owner.revision == after.owner.revision else { throw AdmissionReadFailure.changed }
        return try zip(selected, reply.pairs).map { w,pair in
            guard let a = before.owner.members.firstIndex(where: { $0.id.element == w.id }),
                  let b = after.owner.members.firstIndex(where: { $0.id.element == w.id }),
                  before.owner.members[a] == after.owner.members[b] else { throw AdmissionReadFailure.changed }
            func enrich(_ sample: AdmissionSample, from f: AdmissionFixture, index: Int) -> AdmissionSample {
                let m = f.owner.members[index], frame = f.owner.frames[index]
                var s = sample
                guard s.permission, s.element != nil, s.axNumber == m.id.number else { return s }
                s.element = m.id.element
                s.selectionContinuity = true
                s.minimum = s.minimum.map { .init(width: max($0.width,m.minimum.width), height: max($0.height,m.minimum.height)) } ?? m.minimum
                s.fullscreen = s.fullscreen ?? false
                s.minimized = s.minimized ?? false
                if !f.owner.editing { s.editGeneration = f.owner.editTokens[m.identifier]?.uuidString }
                s.recoveryVerified = s.axFrame == frame && s.cgFrame == frame && s.display == f.run.screens.secondary
                    && s.editGeneration != nil && !f.owner.editing
                return s
            }
            return AdmissionPair(first: enrich(pair.first,from:before,index:a), second: enrich(pair.second,from:after,index:b))
        }
    }
    func safeguards(_ app: AdmissionApplication) -> (exclusive: Bool?, recoveryClear: Bool?) {
        fixture(app)?.safeguards() ?? (nil,nil)
    }
    func storedLayout(_ app: AdmissionApplication) -> (layout: ManagedWindowTiler?, originals: [ManagedWindowID:SurfaceRect])? {
        fixture(app)?.storedLayout()
    }
    private func read(_ app: AdmissionApplication, targets: [AdmissionReadRequest.Target]) async throws -> AdmissionReadReply {
        let r = AdmissionReadRequest(parent: getpid(), pid: app.pid, launch: app.launch, bundle: app.bundle, targets: targets)
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NearpaneDesktopReader")
        guard let expected = Bundle.main.object(forInfoDictionaryKey: "NearpaneDesktopReaderSHA256") as? String,
              executable.resolvingSymlinksInPath().path == executable.path else { throw AdmissionReadFailure.unavailable }
        let job = Task.detached(priority: .userInitiated) {
            let file = try Data(contentsOf: executable, options: .mappedIfSafe)
            guard SHA256.hash(data: file).map({ String(format: "%02x",$0) }).joined() == expected else { throw AdmissionReadFailure.unavailable }
            let data = try JSONEncoder().encode(r)
            guard data.count <= 12_288 else { throw AdmissionReadFailure.unknown }
            let bytes = try DesktopReaderProcess.collect(executable: executable, mode: "--admission", argument: data.base64EncodedString(), timeout: 4)
            return try JSONDecoder().decode(AdmissionReadReply.self,from:bytes)
        }
        let reply: AdmissionReadReply
        do { reply = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() } }
        catch { throw AdmissionReadFailure.unavailable }
        guard reply.nonce == r.nonce, reply.numbers.count <= 64, targets.isEmpty || reply.numbers.isEmpty,
              targets.count == reply.pairs.count, zip(targets,reply.pairs).allSatisfy({ t,p in
                  [p.first,p.second].allSatisfy { $0.pid == app.pid && $0.launch == app.launch && $0.number == t.number && $0.bundle == app.bundle }
              }) else { throw AdmissionReadFailure.changed }
        return reply
    }
}
