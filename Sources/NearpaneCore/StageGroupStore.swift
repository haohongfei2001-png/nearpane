import Foundation
import Observation

/// A read-only partition. Neither UUID is a destination for native window operations.
public struct StageGroupScope: Hashable, Codable, Sendable {
    public let display: UUID
    public let nativeSpace: UUID
    public init(display: UUID, nativeSpace: UUID) { self.display = display; self.nativeSpace = nativeSpace }
}

/// Group identity belongs to Nearpane. Partition provenance survives a restart; AX authority never does.
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
        public var nativeSpace: UUID?
        public var needsReorganization: Bool?
        public var verifiedActive: Bool?
    }

    public struct Display: Codable, Equatable, Identifiable, Sendable {
        public let id: UUID
        public var groups: [Group]
        /// Legacy v1 field, cleared when migrating. New activity is unique within each ordinary Space.
        public var activeGroup: UUID?
    }

    public let version: Int
    public var displays: [Display]

    fileprivate func validate() throws {
        var ids = Set<UUID>(), windows = Set<NativeSpaceWindow>()
        guard version == 1 || version == 2 else { throw StageGroupError.invalidDirectory }
        for display in displays {
            guard ids.insert(display.id).inserted,
                  display.activeGroup.map({ id in display.groups.contains { $0.id == id } }) != false
            else { throw StageGroupError.invalidDirectory }
            var activeSpaces = Set<UUID>()
            for group in display.groups {
                if group.verifiedActive == true {
                    guard version == 2, group.needsReorganization != true, let space = group.nativeSpace,
                          activeSpaces.insert(space).inserted else { throw StageGroupError.invalidDirectory }
                }
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
    public let nativeSpace: UUID?
    public let layout: SurfaceRect?

    public init(display: UUID, identity: NativeSpaceWindow, lifetime: UUID, layout: SurfaceRect? = nil, nativeSpace: UUID? = nil) {
        self.display = display
        self.identity = identity
        self.lifetime = lifetime
        self.nativeSpace = nativeSpace
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
    public private(set) var directory = StageGroupDirectory(version: 2, displays: [])
    public private(set) var loadIssue: String?
    private let file: URL?, legacy: URL?
    @ObservationIgnored private var legacyOriginal: Data?
    @ObservationIgnored private var original: Data?
    private var bindings = [NativeSpaceWindow: UUID]()

    /// The Host supplies its exclusively leased profile directory. A nil location is an in-memory fixture.
    public init(profile: URL?) {
        file = profile?.appendingPathComponent("stage-groups-v2.json")
        legacy = profile?.appendingPathComponent("stage-groups-v1.json")
        guard let file else { return }
        do {
            original = try Self.read(file)
            if let original {
                let loaded = try JSONDecoder().decode(StageGroupDirectory.self, from: original)
                try loaded.validate()
                guard loaded.version == 2, loaded.displays.allSatisfy({ $0.activeGroup == nil }) else { throw StageGroupError.invalidDirectory }
                directory = loaded
            } else if let legacy, let old = try Self.read(legacy) {
                legacyOriginal = old
                let previous = try JSONDecoder().decode(StageGroupDirectory.self, from: old)
                try previous.validate()
                guard previous.version == 1 else { throw StageGroupError.invalidDirectory }
                var migrated = StageGroupDirectory(version: 2, displays: previous.displays)
                for d in migrated.displays.indices {
                    migrated.displays[d].activeGroup = nil
                    for g in migrated.displays[d].groups.indices {
                        migrated.displays[d].groups[g].nativeSpace = nil
                        migrated.displays[d].groups[g].needsReorganization = nil
                        migrated.displays[d].groups[g].verifiedActive = nil
                    }
                }
                directory = migrated
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
            let legacyUnchanged = try original != nil || legacy.flatMap(Self.read) == legacyOriginal
            guard try Self.read(file) == original, legacyUnchanged else {
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
            let group = StageGroupDirectory.Group(id: UUID(), members: [member], nativeSpace: window.nativeSpace)
            if let index = next.displays.firstIndex(where: { $0.id == window.display }) {
                next.displays[index].groups.append(group)
            } else {
                next.displays.append(.init(id: window.display, groups: [group]))
            }
            additions[window.identity] = window.lifetime
        }
        for d in next.displays.indices {
            for g in next.displays[d].groups.indices {
                var group = next.displays[d].groups[g]
                let live = group.members.compactMap { member -> StageGroupWindow? in
                    guard let candidates = occurrences[member.windowHint], candidates.count == 1 else { return nil }
                    return candidates[0]
                }
                let observedSpaces = Set(live.compactMap(\.nativeSpace))
                let moved = live.contains { $0.display != next.displays[d].id } ||
                    group.nativeSpace.map { !observedSpaces.subtracting([$0]).isEmpty } == true
                if moved || observedSpaces.count > 1 {
                    group.needsReorganization = true
                    group.verifiedActive = nil
                } else if live.count == group.members.count,
                          live.allSatisfy({ $0.nativeSpace != nil && bindings[$0.identity] == $0.lifetime }), observedSpaces.count == 1 {
                    group.nativeSpace = observedSpaces.first
                    group.needsReorganization = nil
                }
                next.displays[d].groups[g] = group
            }
        }
        try commit(next)
        if !additions.isEmpty { bindings.merge(additions) { _, new in new } }
    }

    public func groups(on display: UUID) -> [StageGroupDirectory.Group] {
        directory.displays.first { $0.id == display }?.groups ?? []
    }

    public func groups(in scope: StageGroupScope) -> [StageGroupDirectory.Group] {
        groups(on: scope.display).filter { $0.nativeSpace == scope.nativeSpace }
    }

    public func activeGroup(in scope: StageGroupScope) -> UUID? {
        groups(in: scope).first { $0.verifiedActive == true }?.id
    }

    /// A baseline belongs to one active group and its genuinely focused, live member. A remembered
    /// directory entry after restart cannot establish it.
    public struct ArrivalBaseline {
        public let group: UUID, source: NativeSpaceWindow, sample: StageWindowSample
        public let directory: StageGroupDirectory
    }

    public func arrivalBaseline(_ sample: StageWindowSample) -> ArrivalBaseline? {
        guard loadIssue == nil, (sample.nativeID ?? 0) > 0, let focus = sample.focus,
              let focused = sample.windows[focus], focused.visibility == .visible,
              let group = groups(in: sample.scope).first(where: { $0.verifiedActive == true && $0.needsReorganization != true }),
              let member = group.members.first(where: { $0.windowHint == focus }), isBound(member, to: focused.lifetime)
        else { return nil }
        return .init(group: group.id, source: focus, sample: sample, directory: directory)
    }

    /// Called only for an original AXWindowCreated event. All earlier windows, the physical partition,
    /// and the focused origin must survive its two independent samples. This only writes the directory.
    public func recordCreatedWindow(_ key: NativeSpaceWindow, since baseline: ArrivalBaseline,
                                    first: StageWindowSample, second: StageWindowSample) throws {
        let before = baseline.sample, source = baseline.source
        let scope = before.scope
        guard directory == baseline.directory, activeGroup(in: scope) == baseline.group,
              source.pid == key.pid, source.birth == key.birth, key.number != source.number,
              !directory.displays.flatMap(\.groups).flatMap(\.members).contains(where: { $0.windowHint.number == key.number }),
              !before.windows.keys.contains(where: { $0.number == key.number }),
              first.scope == scope, second.scope == scope, first.generation == before.generation, second.generation == before.generation,
              before.sequence < first.sequence, first.sequence < second.sequence, (before.nativeID ?? 0) > 0,
              first.nativeID == before.nativeID, second.nativeID == before.nativeID,
              first.workArea == before.workArea, second.workArea == before.workArea,
              first.windows.count == before.windows.count + 1, first.windows == second.windows,
              before.windows.allSatisfy({ first.windows[$0.key] == $0.value }),
              let new = first.windows[key], new.window == key, new.visibility == .visible,
              !before.windows.values.contains(where: { $0.lifetime == new.lifetime }),
              first.focus == second.focus, first.focus == source || first.focus == key,
              let layout = StageGroupWindow.relativeFrame(new.frame, in: second.workArea),
              let d = directory.displays.firstIndex(where: { $0.id == scope.display }),
              let g = directory.displays[d].groups.firstIndex(where: { $0.id == baseline.group })
        else { throw StageGroupError.staleBinding }
        var next = directory
        next.displays[d].groups[g].members.append(.init(id: UUID(), windowHint: key, layout: layout))
        try commit(next)
        bindings[key] = new.lifetime
    }

    /// Called only by the coordinator once a whole-transaction independent readback is complete.
    func commitActivity(_ group: UUID, preferred: UUID, in scope: StageGroupScope,
                        expected: StageGroupDirectory) throws {
        guard directory == expected else { throw StageGroupError.changedFile }
        var next = directory
        guard let d = next.displays.firstIndex(where: { $0.id == scope.display }),
              let g = next.displays[d].groups.firstIndex(where: { $0.id == group && $0.nativeSpace == scope.nativeSpace }),
              next.displays[d].groups[g].needsReorganization != true,
              next.displays[d].groups[g].members.contains(where: { $0.id == preferred }) else { throw StageGroupError.staleBinding }
        for index in next.displays[d].groups.indices where next.displays[d].groups[index].nativeSpace == scope.nativeSpace {
            next.displays[d].groups[index].verifiedActive = index == g ? true : nil
        }
        next.displays[d].groups[g].selectedMember = preferred
        try commit(next)
    }

    func withdrawActivity(in scopes: Set<StageGroupScope>) throws {
        var next = directory
        for index in next.displays.indices {
            let display = next.displays[index].id
            for group in next.displays[index].groups.indices {
                guard let space = next.displays[index].groups[group].nativeSpace,
                      scopes.contains(.init(display: display, nativeSpace: space)) else { continue }
                next.displays[index].groups[group].verifiedActive = nil
            }
        }
        if next != directory { try commit(next) }
    }

    func isBound(_ member: StageGroupDirectory.Member, to lifetime: UUID) -> Bool { bindings[member.windowHint] == lifetime }

    /// Partial, stale and other-display groups have no actionable composite card.
    public func projectedGroups(on display: UUID, among windows: [StageGroupWindow]) -> [StageGroupDirectory.Group] {
        let candidates = Dictionary(grouping: windows.filter { $0.display == display }, by: \.identity)
        return groups(on: display).filter { group in
            group.needsReorganization != true && group.members.allSatisfy { member in
                let matches = candidates[member.windowHint]
                guard matches?.count == 1, let match = matches?.first else { return false }
                return bindings[member.windowHint] == match.lifetime && group.nativeSpace == match.nativeSpace
            }
        }
    }

    public func previousDisplay(of window: StageGroupWindow) -> UUID? {
        directory.displays.first { display in
            display.id != window.display && display.groups.contains { $0.members.contains { $0.windowHint == window.identity } }
        }?.id
    }

    /// This can also represent a native Mission Control move within one physical display.
    public func needsReassignment(_ window: StageGroupWindow) -> Bool {
        directory.displays.contains { d in d.groups.contains { g in
            g.members.contains { $0.windowHint == window.identity } &&
                (d.id != window.display || (g.nativeSpace != nil && window.nativeSpace != nil && g.nativeSpace != window.nativeSpace))
        } }
    }

    /// An explicit roster edit after macOS or the user has already moved the window onto another display.
    public func assignToObservedDisplay(_ window: StageGroupWindow) throws {
        var next = directory
        guard needsReassignment(window), let d = next.displays.firstIndex(where: { $0.groups.contains { $0.members.contains { $0.windowHint == window.identity } } }),
              let g = next.displays[d].groups.firstIndex(where: { $0.members.contains { $0.windowHint == window.identity } }),
              let m = next.displays[d].groups[g].members.firstIndex(where: { $0.windowHint == window.identity })
        else { throw StageGroupError.wrongDisplay }
        let oldGroup = next.displays[d].groups[g].id
        next.displays[d].groups[g].verifiedActive = nil
        var member = next.displays[d].groups[g].members.remove(at: m)
        member.layout = window.layout
        if next.displays[d].groups[g].selectedMember == member.id { next.displays[d].groups[g].selectedMember = nil }
        if next.displays[d].activeGroup == oldGroup { next.displays[d].activeGroup = nil }
        next.displays[d].groups.removeAll { $0.members.isEmpty }
        let single = StageGroupDirectory.Group(id: UUID(), members: [member], nativeSpace: window.nativeSpace)
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
        loadIssue == nil && !needsReassignment(window) && bindings[window.identity] != window.lifetime &&
            groups(on: window.display).contains { $0.members.contains { $0.windowHint == window.identity } }
    }

    public func rebind(_ window: StageGroupWindow) throws {
        guard needsRebinding(window) else { throw StageGroupError.staleBinding }
        bindings[window.identity] = window.lifetime
    }

    /// Transfer only the dragged member. Preserve other members, group order and their last verified geometry.
    public func join(_ moving: StageGroupWindow, to target: StageGroupWindow) throws {
        guard moving.display == target.display, moving.nativeSpace == target.nativeSpace else { throw StageGroupError.wrongDisplay }
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
        guard let source = location(moving.identity), let destination = location(target.identity),
              [source.group, destination.group].allSatisfy({ display.groups[$0].nativeSpace == target.nativeSpace &&
                  display.groups[$0].needsReorganization != true }) else { throw StageGroupError.staleBinding }
        if let frame = target.layout { display.groups[destination.group].members[destination.member].layout = frame }
        if let frame = moving.layout { display.groups[source.group].members[source.member].layout = frame }
        if source.group != destination.group {
            display.groups[source.group].verifiedActive = nil
            display.groups[destination.group].verifiedActive = nil
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
        next.displays[d].groups[g].verifiedActive = nil
        if next.displays[d].groups[g].selectedMember == member.id { next.displays[d].groups[g].selectedMember = nil }
        if next.displays[d].activeGroup == next.displays[d].groups[g].id { next.displays[d].activeGroup = nil }
        next.displays[d].groups.insert(.init(id: UUID(), members: [member], nativeSpace: window.nativeSpace), at: g + 1)
        try commit(next)
    }

    /// Dissolution is a roster edit. Each window keeps its logical slot, binding and last layout.
    public func dissolve(_ id: UUID, on display: UUID) throws {
        var next = directory
        guard let d = next.displays.firstIndex(where: { $0.id == display }),
              let g = next.displays[d].groups.firstIndex(where: { $0.id == id }) else { throw StageGroupError.wrongDisplay }
        let old = next.displays[d].groups[g]
        guard old.members.count > 1 else { return }
        let singles = old.members.map { StageGroupDirectory.Group(id: UUID(), members: [$0], nativeSpace: old.nativeSpace, needsReorganization: old.needsReorganization) }
        next.displays[d].groups.replaceSubrange(g...g, with: singles)
        if next.displays[d].activeGroup == id { next.displays[d].activeGroup = nil }
        try commit(next)
    }
}
