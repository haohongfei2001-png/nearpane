import Darwin
import Foundation
import NearpaneCore
import WindowLab

struct WindowBaseline: Codable {
    var member: Member
    let initial: SurfaceRect
    var confirmed: SurfaceRect
    func matches(_ actual: Observation) -> Bool {
        actual.member == member && actual.onScreen && actual.cg == confirmed && actual.ax == confirmed
    }
}
struct CandidateLayout: Decodable {
    let configuration: HostConfiguration
    let ratio: Double
    let swap: Bool
    let keepIntent: Bool
}
struct FrameChange: Codable {
    let member: Member, original: SurfaceRect, target: SurfaceRect
    var confirmed: SurfaceRect, inFlight: SurfaceRect?
    var editToken: UUID?
    func permitsProductRecovery(from actual: SurfaceRect, currentEdit: UUID?) -> Bool {
        editToken != nil && editToken == currentEdit && permitsRecovery(from: actual)
    }
    func permitsRecovery(from actual: SurfaceRect) -> Bool {
        actual == original || actual == confirmed || actual == inFlight
    }
}
enum JournalStatus: String, Codable { case prepared, parked, recovering, retained, restored }
struct FrameJournal: Codable {
    let session: UUID, display: String, owner: ProcessBirth, transaction: UUID, revision: Int
    let fromWorkspace: UUID, toWorkspace: UUID
    let parked: Bool, priorLayout: WorkspaceState
    var changes: [FrameChange]
    var status: JournalStatus
}
struct WorkspaceState: Codable {
    let session: UUID, display: String, owner: ProcessBirth
    var layout: ManagedWindowTiler, windows: [WindowBaseline]
}
struct StepReceipt: Codable {
    let member: Member, before: SurfaceRect, requested: SurfaceRect, after: Observation
}
struct ActionReceipt: Codable {
    let action: String, session: UUID, snapshotRevision: Int, setters: Int
    let workRect: SurfaceRect?, maxModelError: Double?, journal: FrameJournal?
    let observations: [Observation], steps: [StepReceipt]
    var creationUnavailableFor: [ManagedWindowID]?
}

final class SessionFiles {
    let dir: URL
    private let lease: Int32
    init(_ dir: URL) throws {
        self.dir = dir
        let fd = open(dir.appendingPathComponent("writer.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Refusal("unable to open writer lease") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw Refusal("another fixture controller holds the lease") }
        lease = fd
    }
    deinit { close(lease) }
    func load<T: Decodable>(_ name: String) throws -> T? {
        let url = dir.appendingPathComponent(name)
        do { return try JSONDecoder().decode(T.self, from: Data(contentsOf: url)) }
        catch let e as CocoaError where e.code == .fileReadNoSuchFile { return nil }
    }
    // File and directory are both synchronized, including the entry installed by rename.
    func persist<T: Encodable>(_ value: T, _ name: String) throws {
        let tmp = dir.appendingPathComponent(".write-" + UUID().uuidString), final = dir.appendingPathComponent(name)
        let url = dir.path
        let folder = open(url, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard folder >= 0 else { throw Refusal("unable to open journal directory") }
        defer { close(folder); unlink(tmp.path) }
        let file = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw Refusal("cannot create journal") }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        try handle.write(contentsOf: JSONEncoder().encode(value))
        try handle.synchronize()
        try handle.close()
        try require(rename(tmp.path, final.path) == 0 && fsync(folder) == 0, "unable to commit journal durably")
    }
}

@MainActor final class Experiment {
    let adapter: FixtureAdapter, files: SessionFiles
    var receipts = [StepReceipt]()
    private var creationFallback: [ManagedWindowID]?
    private var holdBeforeAcknowledgement = false
    init(_ dir: URL, acceptsAX: Bool = true) throws {
        adapter = try FixtureAdapter(dir, acceptsAX: acceptsAX)
        files = try SessionFiles(dir)
        let visibility: VisibilityLog? = try files.load("visibility.json")
        try require(visibility?.settled != false, "visibility recovery pending")
    }
    func observations() throws -> [Observation] { try adapter.ticket.members.map(adapter.observe) }
    func picture(_ action: String, _ journal: FrameJournal? = nil, area: SurfaceRect? = nil, error: Double? = nil) throws -> ActionReceipt {
        try ActionReceipt(action: action, session: adapter.run.session, snapshotRevision: adapter.ticket.revision, setters: adapter.setters,
                          workRect: area, maxModelError: error, journal: journal, observations: observations(), steps: receipts, creationUnavailableFor: creationFallback)
    }
    private func apply(_ j: inout FrameJournal, at i: Int, to target: SurfaceRect) throws {
        let member = j.changes[i].member
        for next in FramePolicy.steps(from: j.changes[i].confirmed, to: target) {
            let current = j.changes[i].confirmed
            try FramePolicy.validateStep(current, next, member: member, screens: adapter.run.screens, parking: j.parked)
            try require(try adapter.observe(member).cg == current, "another writer changed the frame")
            j.changes[i].inFlight = next
            try files.persist(j, "journal.json")
            let after = try adapter.set(member, from: current, to: next, parking: j.parked)
            receipts.append(.init(member: member, before: current, requested: next, after: after))
            if holdBeforeAcknowledgement {
                try files.persist(try picture("AX-confirmed-before-WAL-ack", j), "kill-witness.json")
                let limit = adapter.run.productManagement == true ? ProcessInfo.processInfo.systemUptime + 7 : adapter.run.deadline
                while ProcessInfo.processInfo.systemUptime < limit && getppid() > 1 { usleep(50_000) }
                throw Refusal("kill checkpoint expired")
            }
            j.changes[i].confirmed = after.cg; j.changes[i].inFlight = nil
            try files.persist(j, "journal.json")
        }
        try require(try adapter.observe(member).cg == target, "final frame not confirmed")
    }
    // Sets a single primitive at a time. The before/after pair spans death between AX and its acknowledgement.
    func recover() throws -> ActionReceipt {
        guard var j: FrameJournal = try files.load("journal.json") else { throw Refusal("missing recovery record") }
        if adapter.run.productManagement == true {
            try require(j.session == adapter.run.session && j.owner == adapter.ticket.owner
                && j.display == adapter.run.screens.secondary && !j.changes.isEmpty
                && Set(j.changes.map(\.member.id)).count == j.changes.count, "recovery origin changed")
        } else { try validate(j) }
        try adapter.requireAccess()
        func accessible(_ c: FrameChange) throws -> Bool {
            let o = try adapter.observe(c.member)
            return o.onScreen && o.cg == c.original && adapter.run.screens.usable.geometry.intersection(o.cg.geometry) == o.cg.geometry
        }
        if j.status == .restored {
            for c in j.changes { try require(try accessible(c), "settled window changed") }
            return try picture("already-restored", j)
        }
        try require([.prepared, .parked, .recovering].contains(j.status), "no pending recovery")
        j.status = .recovering; try files.persist(j, "journal.json")
        // If a competing manager or the user changed a window, preserve its current frame and the unsettled journal.
        var deferred = [UInt32]()
        for i in j.changes.indices.reversed() {
            let c = j.changes[i]
            if adapter.run.productManagement == true {
                guard let index = adapter.ticket.members.firstIndex(of: c.member), adapter.ticket.frames.indices.contains(index),
                      let observed = try? adapter.observe(c.member),
                      observed.onScreen && observed.cg == adapter.ticket.frames[index] && c.permitsProductRecovery(from: observed.cg, currentEdit: adapter.ticket.editTokens?[c.member.identifier]) else {
                    deferred.append(c.member.id.number)
                    continue
                }
            }
            let live = try adapter.observe(c.member).cg
            try require(c.permitsRecovery(from: live), "unrecognized frame; retained for inspection")
            if live != c.original { try adapter.writable(c.member) }
            j.changes[i].confirmed = live; j.changes[i].inFlight = nil
            try files.persist(j, "journal.json")
            try apply(&j, at: i, to: c.original)
        }
        try require(deferred.isEmpty, "已恢复可核对的窗口；其余保留待处理 \(deferred)")
        try require(try j.changes.allSatisfy(accessible), "restored windows not accessible")
        try files.persist(j.priorLayout, "layout.json")
        j.status = .restored; try files.persist(j, "journal.json")
        return try picture("restored", j)
    }
    func validate(_ j: FrameJournal) throws {
        try require(j.session == adapter.run.session && j.owner == adapter.ticket.owner && j.revision == adapter.ticket.revision
            && j.display == adapter.run.screens.secondary && !j.changes.isEmpty
            && Set(j.changes.map(\.member.id)).count == j.changes.count && j.changes.allSatisfy { adapter.ticket.members.contains($0.member) },
            "recovery identity or snapshot revision changed")
    }
    func state(at baseline: [Observation], adopting: Bool = false) throws -> WorkspaceState {
        let run = adapter.run
        if let j: FrameJournal = try files.load("journal.json") {
            try require([.retained, .restored].contains(j.status), "pending recovery requires inspection")
        }
        var state: WorkspaceState = try files.load("layout.json") ??
            .init(session: run.session, display: run.screens.secondary, owner: adapter.ticket.owner,
                  layout: .init(workspace: run.productManagement == true ? nil : .virtual(run.session)), windows: [])
        try require(state.session == run.session && state.display == run.screens.secondary && state.owner == adapter.ticket.owner,
                    "layout owner changed")
        for (index, obs) in baseline.enumerated() {
            if let i = state.windows.firstIndex(where: { $0.member.id == obs.member.id }) {
                if run.productManagement == true {
                    try require(state.windows[i].member.identifier == obs.member.identifier, "member identity changed")
                    state.windows[i].member = obs.member
                }
                let old = state.windows[i]
                if adopting && adapter.run.productManagement == true {
                    try require(obs.member == old.member && obs.ax == obs.cg && obs.onScreen
                        && obs.cg.geometry.intersection(run.screens.usable.geometry) == obs.cg.geometry, "unsafe user frame")
                } else { try require(old.matches(obs), "external layout change") }
            } else {
                try require(!state.windows.contains { $0.member.id.number == obs.member.id.number && $0.member.id != obs.member.id },
                            "CG window number reused")
                try require(adapter.ticket.frames.indices.contains(index) && adapter.ticket.members[index] == obs.member
                    && adapter.ticket.frames[index] == obs.cg && obs.cg == obs.ax && obs.onScreen
                    && run.screens.usable.geometry.intersection(obs.cg.geometry) == obs.cg.geometry,
                            "new fixture changed since enrollment")
                state.windows.append(.init(member: obs.member, initial: obs.cg, confirmed: obs.cg))
            }
        }
        return state
    }
    func begin(_ action: String) throws -> ActionReceipt {
        // Validate and journal the same observation. Reading a new baseline after approval would adopt a competing edit.
        let before = try observations()
        if adapter.run.productManagement == true {
            try require(before.map(\.cg) == adapter.ticket.frames, "窗口在呈现核对后发生变化")
        }
        var state = try state(at: before, adopting: action == "candidate-adopt")
        let run = adapter.run, screens = run.screens, members = adapter.ticket.members
        let switching = action == "switch" || action == "switch-and-hold"
        let park = action == "park" || switching, canary = action == "canary" || action == "canary-and-hold"
        holdBeforeAcknowledgement = action == "canary-and-hold"
        let acceptance = adapter.directory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if run.productManagement == true && action == "candidate-layout"
            && acceptance.deletingLastPathComponent().lastPathComponent == "native-acceptance"
            && ProcessInfo.processInfo.environment["NEARPANE_MANAGEMENT_ACCEPTANCE"] == acceptance.lastPathComponent
            && UUID(uuidString: acceptance.lastPathComponent) != nil {
            let mark = acceptance.appendingPathComponent("stop-before-ack.once")
            if unlink(mark.path) == 0 { holdBeforeAcknowledgement = true }
        }
        if park {
            let grant = VirtualWorkspacesProvider().deviceCapabilities(build: ProcessInfo.processInfo.operatingSystemVersionString, displayID: screens.secondary)
            try require(grant.permits(.switchRow, isolated: false), "no device-verified Virtual parking mechanism")
        }
        if switching { try require(members.count == 2, "switch requires exactly two enrolled windows") }
        var settings = DisplaySettings()
        settings.placement = action == "floating" ? .floating : .docked
        if action == "reserve" { settings.measures[.reservedWidth] = Measure(20, .percent) }
        var primary = false, edge = SurfaceEdge.left
        var preferences: WorkspacePreferences?
        var pairRatio = 0.62, swap = true, retainIntent = false
        if action.hasPrefix("candidate-") {
            let request: CandidateLayout = try readJSON(adapter.directory, "candidate.json")
            let config = try request.configuration.validated()
            // The whole group is one transaction. An exclusion refuses it before the WAL or first setter.
            for member in members {
                try require(try !config.workspaces.excluded(member.id, bundle: "org.nearpane.lab.NearpaneFixtureWindows"), "excluded test window")
            }
            preferences = config.workspaces
            settings = config.displays[screens.secondary] ?? .init()
            primary = config.preferredDisplayID == screens.secondary
            edge = config.edge
            pairRatio = request.ratio
            swap = request.swap
            retainIntent = request.keepIntent && members.count == 2
            try require(pairRatio.isFinite && (0.2...0.8).contains(pairRatio), "pair ratio out of range")
        }
        let exiting = action == "candidate-exit"
        let area = try DesktopWorkArea(display: screens.secondary, screen: screens.frame, usable: screens.usable,
                                       primary: primary, settings: settings, fallbackEdge: edge)
        var layout = state.layout
        for m in layout.members where !members.contains(where: { $0.id == m.id }) { layout = try layout.removing(m.id, in: area.ordinary) }
        if run.productManagement == true { creationFallback = [] }
        for m in members where !layout.members.contains(where: { $0.id == m.id }) {
            if let preferences, WorkspaceAdmissionPlanner.requestsCreation(existingCount: layout.members.count,
                                                                           source: .application, preferences: preferences) {
                creationFallback?.append(m.id)
            }
            layout = try layout.adding(m.managed, in: area.ordinary)
        }
        if action == "custom-pair" || action == "candidate-pair" || action == "candidate-adopt" {
            try require(members.count == 2, "custom pair requires two windows")
            if action == "candidate-adopt" {
                (pairRatio, swap) = try observedPair(before, state: state, area: area.ordinary)
            }
            if action.hasPrefix("candidate-") {
                // Start from a canonical pair so applying the same explicit slot choice is idempotent.
                layout = try ManagedWindowTiler(workspace: state.layout.workspace).adding(members[0].managed, in: area.ordinary)
                    .adding(members[1].managed, in: area.ordinary)
            }
            layout = try layout.adjusting(path: [], axis: .columns, ratio: pairRatio, in: area.ordinary)
            if swap { layout = try layout.swapping(members[0].id, members[1].id, in: area.ordinary) }
        }
        retainIntent = retainIntent || (adapter.run.productManagement == true && layout.userAdjusted)
        if run.productManagement == true {
            layout = try layout.refreshingRequirements(members.map(\.managed), in: area.ordinary)
        }
        let modelArea = exiting && retainIntent ? screens.usable : area.ordinary
        let model = try layout.frames(in: modelArea)
        var moves = [FrameChange]()
        for o in before {
            let target: SurfaceRect
            if park {
                guard o.member == members.first || switching else { continue }
                target = o.member == members.first ? try FramePolicy.parkingFrame(o.cg, screens: screens) : o.cg
            } else if canary {
                try require(members.count == 1, "canary requires one fixture")
                var trial = o.cg; trial.x += 14; trial.y += 9
                try require(screens.usable.geometry.intersection(trial.geometry) == trial.geometry, "canary not inside secondary")
                target = trial
            } else if action == "original" || (exiting && !retainIntent) {
                guard let baseline = state.windows.first(where: { $0.member == o.member }) else { throw Refusal("missing original") }
                target = baseline.initial
            } else {
                guard let plan = model[o.member.id] else { throw Refusal("missing layout slot") }
                target = Self.lattice(plan)
            }
            var previous = o.cg
            for step in FramePolicy.steps(from: o.cg, to: target) {
                try FramePolicy.validateStep(previous, step, member: o.member, screens: screens, parking: park)
                previous = step
            }
            try adapter.writable(o.member)
            moves.append(.init(member: o.member, original: o.cg, target: target, confirmed: o.cg, inFlight: nil,
                               editToken: adapter.ticket.editTokens?[o.member.identifier]))
        }
        let groupB = park ? UUID() : run.session
        var journal = FrameJournal(session: run.session, display: screens.secondary, owner: adapter.ticket.owner, transaction: UUID(),
                                   revision: adapter.ticket.revision, fromWorkspace: run.session, toWorkspace: groupB, parked: park, priorLayout: state, changes: moves, status: .prepared)
        try validate(journal)
        try files.persist(journal, "journal.json")
        if switching {
            let b = moves[1], off = try FramePolicy.parkingFrame(b.original, screens: screens)
            try apply(&journal, at: 1, to: off)
            let seen = try observations()
            try require(seen[0].cg == moves[0].original && seen[0].onScreen && seen[1].cg == off,
                        "source group A not confirmed")
            try files.persist(try picture("active-A", journal), "source-" + journal.transaction.uuidString + ".json")
        }
        for i in moves.indices { try apply(&journal, at: i, to: moves[i].target) }
        let final = try observations()
        // Read the entire group again after the last write, including siblings that should not have moved.
        for o in final {
            let expected = moves.first(where: { $0.member == o.member })?.target ?? before.first { $0.member == o.member }?.cg
            try require(o.cg == expected, "group readback changed")
            if !park || o.member != members.first { try require(o.onScreen, "expected accessible window") }
        }
        var error: Double?
        if park {
            guard let off = moves.first?.target.geometry else { throw Refusal("missing parked window") }
            try require(off.intersection(screens.frame.geometry) == nil && off.intersection(screens.mainFrame.geometry) == nil, "window still visible")
        } else if !canary && action != "original" && (!exiting || retainIntent) {
            let all = final.map(\.cg)
            try require(all.allSatisfy { Self.lattice(modelArea).geometry.intersection($0.geometry) == $0.geometry }
                && all.enumerated().allSatisfy { i, f in all.dropFirst(i + 1).allSatisfy { f.geometry.intersection($0.geometry) == nil } }
                && all.reduce(0) { $0 + $1.geometry.area } == Self.lattice(modelArea).geometry.area, "layout overlap, gaps or bounds")
            error = final.compactMap { obs in model[obs.member.id].map { $0.geometry.componentError(from: obs.cg.geometry) } }.max()
            try require(error.map { $0 <= 1 } == true, "excess work area error")
        }
        if !park && !canary {
            for o in final {
                if let i = state.windows.firstIndex(where: { $0.member == o.member }) { state.windows[i].confirmed = o.cg }
            }
            state.layout = layout
            // layout.json may lead the final journal acknowledgement. Recovery repairs its confirmed frames.
            try files.persist(state, "layout.json")
        }
        journal.status = park ? .parked : (canary ? .prepared : .retained)
        try files.persist(journal, "journal.json")
        let result = try picture(action, journal, area: park || canary || action == "original" ? nil : area.ordinary, error: error)
        if action == "switch-and-hold" {
            try files.persist(result, "parked-witness.json")
            // The supervisor kills only this exact child after an independent observer verifies the parked frame.
            while ProcessInfo.processInfo.systemUptime < run.deadline && getppid() == run.parent.pid { usleep(100_000) }
            throw Refusal("kill checkpoint expired")
        }
        return result
    }
    static func lattice(_ r: SurfaceRect) -> SurfaceRect {
        .init(x: r.x.rounded(), y: r.y.rounded(), width: (r.x+r.width).rounded()-r.x.rounded(),
              height: (r.y+r.height).rounded()-r.y.rounded())
    }
}
