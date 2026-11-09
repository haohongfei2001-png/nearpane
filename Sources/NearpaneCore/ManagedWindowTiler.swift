import Foundation

public struct ManagedMember: Codable, Equatable, Sendable {
    public let id: ManagedWindowID
    public let minimumWidth, minimumHeight: Double
    public let canResize: Bool
    public init(_ id: ManagedWindowID, minimumWidth: Double, minimumHeight: Double, canResize: Bool) {
        self.id = id; self.minimumWidth = minimumWidth; self.minimumHeight = minimumHeight; self.canResize = canResize
    }
}

public enum SplitAxis: String, Codable, Sendable { case columns, rows }
public indirect enum SlotPartition: Codable, Equatable, Sendable {
    case slot(Int)
    case split(SplitAxis, Double, SlotPartition, SlotPartition)

    fileprivate func replacing(_ slot: Int, with new: Self) -> Self {
        switch self {
        case .slot(let index): return index == slot ? new : self
        case let .split(axis, ratio, a, b): return .split(axis, ratio, a.replacing(slot, with: new), b.replacing(slot, with: new))
        }
    }

    fileprivate func adjust(path: ArraySlice<Bool>, axis: SplitAxis, ratio: Double) throws -> Self {
        guard case let .split(oldAxis, oldRatio, a, b) = self, ratio.isFinite, ratio > 0, ratio < 1
        else { throw WorkspaceFailure.invalidLayout }
        guard let second = path.first else { return .split(axis, ratio, a, b) }
        if second { return .split(oldAxis, oldRatio, a, try b.adjust(path: path.dropFirst(), axis: axis, ratio: ratio)) }
        return .split(oldAxis, oldRatio, try a.adjust(path: path.dropFirst(), axis: axis, ratio: ratio), b)
    }

    fileprivate func project(_ rect: SurfaceRect, members: [ManagedMember], into frames: inout [ManagedWindowID: SurfaceRect],
                             depth: Int = 0) throws {
        guard rect.geometry.isValid, depth <= 8 else { throw WorkspaceFailure.invalidLayout }
        switch self {
        case .slot(let index):
            guard members.indices.contains(index), frames[members[index].id] == nil else { throw WorkspaceFailure.invalidLayout }
            let member = members[index]
            guard member.canResize else { throw WorkspaceFailure.permission }
            guard member.minimumWidth.isFinite, member.minimumHeight.isFinite, member.minimumWidth > 0,
                  member.minimumHeight > 0, rect.width >= member.minimumWidth, rect.height >= member.minimumHeight
            else { throw WorkspaceFailure.minimumSize }
            frames[member.id] = rect
        case let .split(axis, ratio, first, second):
            guard ratio.isFinite, ratio > 0, ratio < 1 else { throw WorkspaceFailure.invalidLayout }
            var a = rect, b = rect
            if axis == .columns {
                a.width = rect.width * ratio
                b.x += a.width; b.width -= a.width
            } else {
                a.height = rect.height * ratio
                b.y += a.height; b.height -= a.height
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
    public init(workspace: WorkspaceID) { self.workspace = workspace }

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
        return tree
    }

    public func frames(in area: SurfaceRect) throws -> [ManagedWindowID: SurfaceRect] {
        guard area.geometry.isValid, members.count <= 8, (partition == nil) == members.isEmpty,
              Set(members.map(\.id)).count == members.count else { throw WorkspaceFailure.invalidLayout }
        var frames = [ManagedWindowID: SurfaceRect]()
        try partition?.project(area, members: members, into: &frames)
        guard frames.count == members.count else { throw WorkspaceFailure.invalidLayout }
        return frames
    }

    public func adding(_ member: ManagedMember, in area: SurfaceRect) throws -> Self {
        guard members.count < 8 else { throw WorkspaceFailure.capacity }
        guard !members.contains(where: { $0.id == member.id }) else { throw WorkspaceFailure.membership }
        var next = self
        next.members.append(member); next.partition = Self.template(next.members.count)
        _ = try next.frames(in: area)
        return next
    }
    public func removing(_ id: ManagedWindowID, in area: SurfaceRect) throws -> Self {
        guard members.contains(where: { $0.id == id }) else { throw WorkspaceFailure.membership }
        var next = self
        next.members.removeAll { $0.id == id }; next.partition = Self.template(next.members.count)
        _ = try next.frames(in: area)
        return next
    }
    public func adjusting(path: [Bool], axis: SplitAxis, ratio: Double, in area: SurfaceRect) throws -> Self {
        guard let partition else { throw WorkspaceFailure.invalidLayout }
        var next = self
        next.partition = try partition.adjust(path: path[...], axis: axis, ratio: ratio)
        _ = try next.frames(in: area)
        return next
    }
    public func swapping(_ a: ManagedWindowID, _ b: ManagedWindowID, in area: SurfaceRect) throws -> Self {
        guard let ia = members.firstIndex(where: { $0.id == a }), let ib = members.firstIndex(where: { $0.id == b }),
              let partition else { throw WorkspaceFailure.membership }
        var next = self
        next.partition = partition.replacing(ia, with: .slot(-1)).replacing(ib, with: .slot(ia)).replacing(-1, with: .slot(ib))
        _ = try next.frames(in: area)
        return next
    }
}
