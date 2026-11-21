import Foundation
import Observation

/// Membership belongs to the display. Native Space observations and live AX authority never enter this file.
public struct StageGroupDirectory: Codable, Equatable, Sendable {
    public struct Member: Codable, Equatable, Identifiable, Sendable {
        public let id: UUID
        public let windowHint: NativeSpaceWindow
        public var layout: SurfaceRect?
    }

    public struct Group: Codable, Equatable, Identifiable, Sendable {
        public let id: UUID
        public var members: [Member]
        public var selectedMember: UUID?
    }

    public struct Display: Codable, Equatable, Identifiable, Sendable {
        public let id: UUID
        public var groups: [Group]
        /// Set only after a verified visibility transaction. A focus or directory edit never sets this.
        public var activeGroup: UUID?
    }

    public let version: Int
    public var displays: [Display]

    fileprivate func validate() throws {
        var ids = Set<UUID>(), windows = Set<NativeSpaceWindow>()
        guard version == 1 else { throw StageGroupError.invalidDirectory }
        for display in displays {
            guard ids.insert(display.id).inserted,
                  display.activeGroup.map({ id in display.groups.contains { $0.id == id } }) != false
            else { throw StageGroupError.invalidDirectory }
            for group in display.groups {
                guard ids.insert(group.id).inserted, !group.members.isEmpty,
                      group.selectedMember.map({ id in group.members.contains { $0.id == id } }) != false
                else { throw StageGroupError.invalidDirectory }
                for member in group.members {
                    guard ids.insert(member.id).inserted, windows.insert(member.windowHint).inserted,
                          member.windowHint.pid > 1, member.windowHint.birth > 0, member.windowHint.number > 0,
                          member.layout.map(StageGroupWindow.validFrame) != false
                    else { throw StageGroupError.invalidDirectory }
                }
            }
        }
    }
}

public enum StageGroupError: LocalizedError {
    case invalidDirectory, changedFile, staleBinding, wrongDisplay
    public var errorDescription: String? {
        switch self {
        case .invalidDirectory: "调度组资料格式无效，已保留原文件。"
        case .changedFile: "调度组资料已改变，请重新读取。"
        case .staleBinding: "窗口身份已变化，请重新关联。"
        case .wrongDisplay: "窗口和调度组的显示器不一致。"
        }
    }
}

/// The roster token is session-local and qualifies a projection only. Window writes still require an independent AX witness.
public struct StageGroupWindow: Sendable {
    public let display: UUID
    public let identity: NativeSpaceWindow
    public let lifetime: UUID
    public let layout: SurfaceRect?

    public init(display: UUID, identity: NativeSpaceWindow, lifetime: UUID, layout: SurfaceRect? = nil) {
        self.display = display
        self.identity = identity
        self.lifetime = lifetime
        self.layout = layout
    }

    fileprivate static func validFrame(_ rect: SurfaceRect) -> Bool {
        [rect.x, rect.y, rect.width, rect.height, rect.x + rect.width, rect.y + rect.height].allSatisfy(\.isFinite) &&
            rect.width > 0 && rect.height > 0
    }

    public static func relativeFrame(_ frame: SurfaceRect, in workArea: SurfaceRect) -> SurfaceRect? {
        guard validFrame(frame), validFrame(workArea) else { return nil }
        let rect = SurfaceRect(x: (frame.x - workArea.x) / workArea.width, y: (frame.y - workArea.y) / workArea.height,
                               width: frame.width / workArea.width, height: frame.height / workArea.height)
        return validFrame(rect) ? rect : nil
    }
}

@MainActor @Observable public final class StageGroupStore {
    public private(set) var directory = StageGroupDirectory(version: 1, displays: [])
    public private(set) var loadIssue: String?
    private let file: URL?
    @ObservationIgnored private var original: Data?
    private var bindings = [NativeSpaceWindow: UUID]()

    /// The Host supplies its exclusively leased profile directory. A nil location is an in-memory fixture.
    public init(profile: URL?) {
        file = profile?.appendingPathComponent("stage-groups-v1.json")
        guard let file else { return }
        do {
            original = try Self.read(file)
            if let original {
                let loaded = try JSONDecoder().decode(StageGroupDirectory.self, from: original)
                try loaded.validate()
                directory = loaded
            }
        } catch { loadIssue = StageGroupError.invalidDirectory.localizedDescription }
    }

    private static func read(_ file: URL) throws -> Data? {
        do { return try Data(contentsOf: file) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    private func commit(_ updated: StageGroupDirectory) throws {
        guard loadIssue == nil else { throw StageGroupError.invalidDirectory }
        guard updated != directory else { return }
        try updated.validate()
        if let file {
            guard try Self.read(file) == original else {
                loadIssue = StageGroupError.changedFile.localizedDescription
                throw StageGroupError.changedFile
            }
            let bytes = try JSONEncoder().encode(updated)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file, options: .atomic)
            original = bytes
        }
        directory = updated
    }

    /// Discover previously unseen ordinary windows. Disappearance and a matching numeric hint never remove or rebind a slot.
    public func observe(_ windows: [StageGroupWindow]) throws {
        var next = directory
        var known = Set(next.displays.flatMap { $0.groups.flatMap { $0.members.map(\.windowHint) } })
        var additions = [NativeSpaceWindow: UUID]()
        let occurrences = Dictionary(grouping: windows, by: \.identity)
        for window in windows where occurrences[window.identity]?.count == 1 && known.insert(window.identity).inserted {
            let member = StageGroupDirectory.Member(id: UUID(), windowHint: window.identity, layout: window.layout)
            let group = StageGroupDirectory.Group(id: UUID(), members: [member])
            if let index = next.displays.firstIndex(where: { $0.id == window.display }) {
                next.displays[index].groups.append(group)
            } else {
                next.displays.append(.init(id: window.display, groups: [group]))
            }
            additions[window.identity] = window.lifetime
        }
        try commit(next)
        if !additions.isEmpty { bindings.merge(additions) { _, new in new } }
    }

    public func groups(on display: UUID) -> [StageGroupDirectory.Group] {
        directory.displays.first { $0.id == display }?.groups ?? []
    }

    /// Partial, stale and other-display groups have no actionable composite card.
    public func projectedGroups(on display: UUID, among windows: [StageGroupWindow]) -> [StageGroupDirectory.Group] {
        let candidates = Dictionary(grouping: windows.filter { $0.display == display }, by: \.identity)
        return groups(on: display).filter { group in
            group.members.allSatisfy { member in
                let matches = candidates[member.windowHint]
                guard matches?.count == 1, let match = matches?.first else { return false }
                return bindings[member.windowHint] == match.lifetime
            }
        }
    }

    public func previousDisplay(of window: StageGroupWindow) -> UUID? {
        directory.displays.first { display in
            display.id != window.display && display.groups.contains { $0.members.contains { $0.windowHint == window.identity } }
        }?.id
    }

    /// An explicit roster edit after macOS or the user has already moved the window onto another display.
    public func assignToObservedDisplay(_ window: StageGroupWindow) throws {
        var next = directory
        guard let oldID = previousDisplay(of: window), let d = next.displays.firstIndex(where: { $0.id == oldID }),
              let g = next.displays[d].groups.firstIndex(where: { $0.members.contains { $0.windowHint == window.identity } }),
              let m = next.displays[d].groups[g].members.firstIndex(where: { $0.windowHint == window.identity })
        else { throw StageGroupError.wrongDisplay }
        let oldGroup = next.displays[d].groups[g].id
        var member = next.displays[d].groups[g].members.remove(at: m)
        member.layout = window.layout
        if next.displays[d].groups[g].selectedMember == member.id { next.displays[d].groups[g].selectedMember = nil }
        if next.displays[d].activeGroup == oldGroup { next.displays[d].activeGroup = nil }
        next.displays[d].groups.removeAll { $0.members.isEmpty }
        let single = StageGroupDirectory.Group(id: UUID(), members: [member])
        if let target = next.displays.firstIndex(where: { $0.id == window.display }) {
            next.displays[target].groups.append(single)
        } else {
            next.displays.append(.init(id: window.display, groups: [single]))
        }
        try commit(next)
        bindings[window.identity] = window.lifetime
    }

    /// Explicit confirmation of one roster card only. The hint cannot independently authorize focus or geometry.
    public func needsRebinding(_ window: StageGroupWindow) -> Bool {
        loadIssue == nil && bindings[window.identity] != window.lifetime &&
            groups(on: window.display).contains { $0.members.contains { $0.windowHint == window.identity } }
    }

    public func rebind(_ window: StageGroupWindow) throws {
        guard needsRebinding(window) else { throw StageGroupError.staleBinding }
        bindings[window.identity] = window.lifetime
    }

    /// Transfer only the dragged member. Preserve other members, group order and their last verified geometry.
    public func join(_ moving: StageGroupWindow, to target: StageGroupWindow) throws {
        guard moving.display == target.display else { throw StageGroupError.wrongDisplay }
        guard moving.identity != target.identity, bindings[moving.identity] == moving.lifetime,
              bindings[target.identity] == target.lifetime else { throw StageGroupError.staleBinding }
        var next = directory
        guard let d = next.displays.firstIndex(where: { $0.id == target.display }) else { throw StageGroupError.wrongDisplay }
        var display = next.displays[d]
        func location(_ id: NativeSpaceWindow) -> (group: Int, member: Int)? {
            for g in display.groups.indices {
                if let m = display.groups[g].members.firstIndex(where: { $0.windowHint == id }) { return (g, m) }
            }
            return nil
        }
        guard let source = location(moving.identity), let destination = location(target.identity) else { throw StageGroupError.staleBinding }
        if let frame = target.layout { display.groups[destination.group].members[destination.member].layout = frame }
        if let frame = moving.layout { display.groups[source.group].members[source.member].layout = frame }
        if source.group != destination.group {
            let member = display.groups[source.group].members.remove(at: source.member)
            display.groups[destination.group].members.append(member)
            if display.groups[source.group].selectedMember == member.id { display.groups[source.group].selectedMember = nil }
            if display.activeGroup == display.groups[source.group].id || display.activeGroup == display.groups[destination.group].id {
                display.activeGroup = nil
            }
            display.groups.removeAll { $0.members.isEmpty }
        }
        next.displays[d] = display
        try commit(next)
    }

    public func detach(_ window: StageGroupWindow) throws {
        guard bindings[window.identity] == window.lifetime else { throw StageGroupError.staleBinding }
        var next = directory
        guard let d = next.displays.firstIndex(where: { $0.id == window.display }),
              let g = next.displays[d].groups.firstIndex(where: { $0.members.contains { $0.windowHint == window.identity } }),
              let m = next.displays[d].groups[g].members.firstIndex(where: { $0.windowHint == window.identity })
        else { throw StageGroupError.wrongDisplay }
        guard next.displays[d].groups[g].members.count > 1 else { return }
        let member = next.displays[d].groups[g].members.remove(at: m)
        if next.displays[d].groups[g].selectedMember == member.id { next.displays[d].groups[g].selectedMember = nil }
        if next.displays[d].activeGroup == next.displays[d].groups[g].id { next.displays[d].activeGroup = nil }
        next.displays[d].groups.insert(.init(id: UUID(), members: [member]), at: g + 1)
        try commit(next)
    }

    /// Dissolution is a roster edit. Each window keeps its logical slot, binding and last layout.
    public func dissolve(_ id: UUID, on display: UUID) throws {
        var next = directory
        guard let d = next.displays.firstIndex(where: { $0.id == display }),
              let g = next.displays[d].groups.firstIndex(where: { $0.id == id }) else { throw StageGroupError.wrongDisplay }
        let old = next.displays[d].groups[g]
        guard old.members.count > 1 else { return }
        let singles = old.members.map { StageGroupDirectory.Group(id: UUID(), members: [$0]) }
        next.displays[d].groups.replaceSubrange(g...g, with: singles)
        if next.displays[d].activeGroup == id { next.displays[d].activeGroup = nil }
        try commit(next)
    }
}
