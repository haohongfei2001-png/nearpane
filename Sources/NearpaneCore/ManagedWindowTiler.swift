import Foundation

public struct ManagedMember: Codable, Equatable, Sendable {
    public let id: ManagedWindowID
    public let minimumWidth, minimumHeight: Double
    public let canResize: Bool
    public init(_ id: ManagedWindowID, minimumWidth: Double, minimumHeight: Double, canResize: Bool) {
        self.id = id
        self.minimumWidth = minimumWidth
        self.minimumHeight = minimumHeight
        self.canResize = canResize
    }
}

public enum SplitAxis: String, Codable, Sendable { case columns, rows }
public indirect enum SlotPartition: Codable, Equatable, Sendable {
    case slot(Int)
    case split(SplitAxis, Double, SlotPartition, SlotPartition)

    fileprivate func replacing(_ slot: Int, with new: Self) -> Self {
        switch self {
        case .slot(let index): return index == slot ? new : self
        case .split(let axis, let ratio, let a, let b):
            return .split(axis, ratio, a.replacing(slot, with: new), b.replacing(slot, with: new))
        }
    }

    fileprivate func leaves(depth: Int = 0) -> [(index: Int, depth: Int)] {
        switch self {
        case .slot(let i): return [(i, depth)]
        case .split(_, _, let a, let b): return a.leaves(depth: depth + 1) + b.leaves(depth: depth + 1)
        }
    }
    fileprivate func remapped(from old: [ManagedWindowID], to current: [ManagedWindowID]) throws -> Self {
        switch self {
        case .slot(let i):
            guard old.indices.contains(i), let index = current.firstIndex(of: old[i]) else {
                throw WorkspaceFailure.identity
            }
            return .slot(index)
        case .split(let axis, let ratio, let a, let b):
            return .split(axis, ratio, try a.remapped(from: old, to: current), try b.remapped(from: old, to: current))
        }
    }

    fileprivate func adjust(path: ArraySlice<Bool>, axis: SplitAxis, ratio: Double) throws -> Self {
        guard case .split(let oldAxis, let oldRatio, let a, let b) = self, ratio.isFinite, ratio > 0, ratio < 1
        else { throw WorkspaceFailure.invalidLayout }
        guard let second = path.first else { return .split(axis, ratio, a, b) }
        if second { return .split(oldAxis, oldRatio, a, try b.adjust(path: path.dropFirst(), axis: axis, ratio: ratio)) }
        return .split(oldAxis, oldRatio, try a.adjust(path: path.dropFirst(), axis: axis, ratio: ratio), b)
    }

    fileprivate func project(
        _ rect: SurfaceRect, members: [ManagedMember], into frames: inout [ManagedWindowID: SurfaceRect],
        depth: Int = 0
    ) throws {
        guard rect.geometry.isValid, depth < members.count else { throw WorkspaceFailure.invalidLayout }
        switch self {
        case .slot(let index):
            guard members.indices.contains(index), frames[members[index].id] == nil else {
                throw WorkspaceFailure.invalidLayout
            }
            let member = members[index]
            guard member.canResize else { throw WorkspaceFailure.permission }
            guard member.minimumWidth.isFinite, member.minimumHeight.isFinite, member.minimumWidth > 0,
                member.minimumHeight > 0, rect.width >= member.minimumWidth, rect.height >= member.minimumHeight
            else { throw WorkspaceFailure.minimumSize }
            frames[member.id] = rect
        case .split(let axis, let ratio, let first, let second):
            guard ratio.isFinite, ratio > 0, ratio < 1 else { throw WorkspaceFailure.invalidLayout }
            var a = rect
            var b = rect
            if axis == .columns {
                a.width = rect.width * ratio
                b.x += a.width
                b.width -= a.width
            } else {
                a.height = rect.height * ratio
                b.y += a.height
                b.height -= a.height
            }
            try first.project(a, members: members, into: &frames, depth: depth + 1)
            try second.project(b, members: members, into: &frames, depth: depth + 1)
        }
    }
}

/// Persistent join order and user partition. Every modification validates a copy before publication.
public struct ManagedWindowTiler: Codable, Equatable, Sendable {
    public let workspace: WorkspaceID
    public private(set) var members: [ManagedMember] = []
    public private(set) var partition: SlotPartition?
    private struct CustomPartition: Codable, Equatable, Sendable { let ids: [ManagedWindowID], tree: SlotPartition }
    private var history: [CustomPartition] = []
    public private(set) var userAdjusted = false
    public init(workspace: WorkspaceID) { self.workspace = workspace }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workspace = try c.decode(WorkspaceID.self, forKey: .workspace)
        members = try c.decode([ManagedMember].self, forKey: .members)
        partition = try c.decodeIfPresent(SlotPartition.self, forKey: .partition)
        history = try c.decodeIfPresent([CustomPartition].self, forKey: .history) ?? []
        userAdjusted = try c.decodeIfPresent(Bool.self, forKey: .userAdjusted) ?? false
    }

    static func template(_ count: Int) -> SlotPartition? {
        typealias P = SlotPartition
        func half(_ axis: SplitAxis, _ a: P, _ b: P) -> P { .split(axis, 0.5, a, b) }
        guard count > 0 else { return nil }
        if count == 1 { return .slot(0) }
        if count == 2 { return half(.columns, .slot(0), .slot(1)) }
        let right = half(.rows, .slot(0), .slot(1))
        if count == 3 { return half(.columns, .slot(2), right) }
        let left = half(.rows, .slot(2), .slot(3))
        if count == 4 { return half(.columns, left, right) }
        var tree = half(.columns, left, half(.rows, half(.columns, .slot(0), .slot(1)), .slot(4)))
        for (new, previous) in [(5, 2), (6, 3), (7, 4)] where new < count {
            tree = tree.replacing(previous, with: half(.columns, .slot(previous), .slot(new)))
        }
        if count > 8 {
            for index in 8..<count {
                // Largest canonical leaf first. Ties preserve join order; alternate the next split axis.
                guard let next = tree.leaves().min(by: { ($0.depth, $0.index) < ($1.depth, $1.index) }) else { return nil }
                let axis: SplitAxis = next.depth.isMultiple(of: 2) ? .columns : .rows
                tree = tree.replacing(next.index, with: half(axis, .slot(next.index), .slot(index)))
            }
        }
        return tree
    }

    public func frames(in area: SurfaceRect) throws -> [ManagedWindowID: SurfaceRect] {
        guard area.geometry.isValid, (partition == nil) == members.isEmpty,
            Set(members.map(\.id)).count == members.count
        else { throw WorkspaceFailure.invalidLayout }
        var frames = [ManagedWindowID: SurfaceRect]()
        try partition?.project(area, members: members, into: &frames)
        guard frames.count == members.count else { throw WorkspaceFailure.invalidLayout }
        return frames
    }

    public func adding(_ member: ManagedMember, in area: SurfaceRect) throws -> Self {
        guard !members.contains(where: { $0.id == member.id }) else { throw WorkspaceFailure.membership }
        var next = self
        next.members.append(member)
        next.partition = Self.template(next.members.count)
        next.userAdjusted = false
        _ = try next.frames(in: area)
        return next
    }
    public func removing(_ id: ManagedWindowID, in area: SurfaceRect) throws -> Self {
        guard members.contains(where: { $0.id == id }) else { throw WorkspaceFailure.membership }
        var next = self
        next.members.removeAll { $0.id == id }
        let ids = next.members.map(\.id)
        if let custom = history.first(where: { Set($0.ids) == Set(ids) }) {
            next.partition = try custom.tree.remapped(from: custom.ids, to: ids)
            next.userAdjusted = true
        } else {
            next.partition = Self.template(ids.count)
            next.userAdjusted = false
        }
        _ = try next.frames(in: area)
        return next
    }
    private mutating func rememberCustomization() {
        guard let partition else { return }
        let ids = members.map(\.id)
        let group = Set(ids)
        history.removeAll { Set($0.ids) == group }
        history.append(.init(ids: ids, tree: partition))
        userAdjusted = true
    }
    public func adjusting(path: [Bool], axis: SplitAxis, ratio: Double, in area: SurfaceRect) throws -> Self {
        guard let partition else { throw WorkspaceFailure.invalidLayout }
        var next = self
        next.partition = try partition.adjust(path: path[...], axis: axis, ratio: ratio)
        next.rememberCustomization()
        _ = try next.frames(in: area)
        return next
    }
    public func swapping(_ a: ManagedWindowID, _ b: ManagedWindowID, in area: SurfaceRect) throws -> Self {
        guard let ia = members.firstIndex(where: { $0.id == a }), let ib = members.firstIndex(where: { $0.id == b }),
            let partition
        else { throw WorkspaceFailure.membership }
        var next = self
        next.partition = partition.replacing(ia, with: .slot(-1)).replacing(ib, with: .slot(ia)).replacing(
            -1, with: .slot(ib))
        next.rememberCustomization()
        _ = try next.frames(in: area)
        return next
    }
}
