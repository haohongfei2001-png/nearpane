import Darwin
import Foundation
import NearpaneCore
import WindowLab

struct WindowBaseline: Codable {
    let member: Member, initial: SurfaceRect
    var confirmed: SurfaceRect
    func matches(_ actual: Observation) -> Bool {
        actual.member == member && actual.onScreen && actual.cg == confirmed && actual.ax == confirmed
    }
}
struct FrameChange: Codable {
    let member: Member, original: SurfaceRect, target: SurfaceRect
    var confirmed: SurfaceRect, inFlight: SurfaceRect?
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
    private var holdBeforeAcknowledgement = false
    init(_ dir: URL, acceptsAX: Bool = true) throws {
        adapter = try FixtureAdapter(dir, acceptsAX: acceptsAX)
        files = try SessionFiles(dir)
    }
    func observations() throws -> [Observation] { try adapter.ticket.members.map(adapter.observe) }
    func picture(_ action: String, _ journal: FrameJournal? = nil, area: SurfaceRect? = nil, error: Double? = nil) throws -> ActionReceipt {
        try ActionReceipt(action: action, session: adapter.run.session, snapshotRevision: adapter.ticket.revision, setters: adapter.setters,
                          workRect: area, maxModelError: error, journal: journal, observations: observations(), steps: receipts)
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
                while getppid() == adapter.run.parent.pid && ProcessInfo.processInfo.systemUptime < adapter.run.deadline { usleep(100_000) }
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
        try validate(j)
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
        for i in j.changes.indices.reversed() {
            let c = j.changes[i], live = try adapter.observe(c.member).cg
            try require(c.permitsRecovery(from: live), "unrecognized frame; retained for inspection")
            if live != c.original { try adapter.writable(c.member) }
            j.changes[i].confirmed = live; j.changes[i].inFlight = nil
            try files.persist(j, "journal.json")
            try apply(&j, at: i, to: c.original)
        }
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
    func state(at baseline: [Observation]) throws -> WorkspaceState {
        let run = adapter.run
        if let j: FrameJournal = try files.load("journal.json") {
            try require([.retained, .restored].contains(j.status), "pending recovery requires inspection")
        }
        var state: WorkspaceState = try files.load("layout.json") ??
            .init(session: run.session, display: run.screens.secondary, owner: adapter.ticket.owner,
                  layout: .init(workspace: .virtual(run.session)), windows: [])
        try require(state.session == run.session && state.display == run.screens.secondary && state.owner == adapter.ticket.owner,
                    "layout owner changed")
        for (index, obs) in baseline.enumerated() {
            if let old = state.windows.first(where: { $0.member.id == obs.member.id }) {
                try require(old.matches(obs), "external layout change")
            } else {
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
        var state = try state(at: before)
        let run = adapter.run, screens = run.screens, members = adapter.ticket.members
        let switching = action == "switch" || action == "switch-and-hold"
        let park = action == "park" || switching, canary = action == "canary" || action == "canary-and-hold"
        holdBeforeAcknowledgement = action == "canary-and-hold"
        if switching { try require(members.count == 2, "switch requires exactly two enrolled windows") }
        var settings = DisplaySettings()
        settings.placement = action == "floating" ? .floating : .docked
        if action == "reserve" { settings.measures[.reservedWidth] = Measure(20, .percent) }
        let area = try DesktopWorkArea(display: screens.secondary, screen: screens.frame, usable: screens.usable,
                                       primary: false, settings: settings, fallbackEdge: .left)
        var layout = state.layout
        for m in layout.members where !members.contains(where: { $0.id == m.id }) { layout = try layout.removing(m.id, in: area.ordinary) }
        for m in members where !layout.members.contains(where: { $0.id == m.id }) { layout = try layout.adding(m.managed, in: area.ordinary) }
        if action == "custom-pair" {
            try require(members.count == 2, "custom pair requires two windows")
            layout = try layout.adjusting(path: [], axis: .columns, ratio: 0.62, in: area.ordinary)
            layout = try layout.swapping(members[0].id, members[1].id, in: area.ordinary)
        }
        let model = try layout.frames(in: area.ordinary)
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
            } else if action == "original" {
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
            moves.append(.init(member: o.member, original: o.cg, target: target, confirmed: o.cg, inFlight: nil))
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
        } else if !canary && action != "original" {
            let all = final.map(\.cg)
            try require(all.allSatisfy { Self.lattice(area.ordinary).geometry.intersection($0.geometry) == $0.geometry }
                && all.enumerated().allSatisfy { i, f in all.dropFirst(i + 1).allSatisfy { f.geometry.intersection($0.geometry) == nil } }
                && all.reduce(0) { $0 + $1.geometry.area } == Self.lattice(area.ordinary).geometry.area, "layout overlap, gaps or bounds")
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
