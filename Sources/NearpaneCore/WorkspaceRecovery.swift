import Foundation

public struct LiveManagedWindow: Equatable, Sendable {
    public let member: ManagedMember, bundle: String?, workspace: WorkspaceID, display: String, frame: SurfaceRect
    public let ordinary: Bool
}
public struct ManagedBaseline: Sendable {
    public let original, lastConfirmed: LiveManagedWindow
}
public enum ExitDisposition: Equatable, Sendable {
    case restore(workspace: WorkspaceID, display: String, frame: SurfaceRect)
    case leaveExcluded, needsAttention
}
public struct TakeoverPreflight {
    public let explicitlyLaunched, priorGrant, journalSettled, exclusive, inventoryComplete: Bool
}

/// These are plans. Only the matching provider may execute and attest an OS change.
public enum WorkspaceRecovery {
    public static func relaunch(
        _ check: TakeoverPreflight, current: WorkspaceSnapshot, windows: [LiveManagedWindow],
        uptime: Double, isolated: Bool
    ) throws -> [LiveManagedWindow] {
        guard check.explicitlyLaunched, check.priorGrant else { throw WorkspaceFailure.permission }
        guard check.journalSettled else { throw WorkspaceFailure.recoveryRequired }
        guard check.exclusive else { throw WorkspaceFailure.conflict }
        guard check.inventoryComplete, current.stable, uptime <= current.validUntil,
            Set(windows.map(\.member.id)).count == windows.count, Set(current.observed.keys) == Set(windows.map(\.member.id))
        else { throw WorkspaceFailure.incompleteInventory }
        var eligible = [LiveManagedWindow]()
        for w in windows where w.ordinary {
            guard current.observed[w.member.id] == w else { throw WorkspaceFailure.identity }
            if try current.preferences.excluded(w.member.id, bundle: w.bundle) { continue }
            let row = try current.validate(w.workspace, action: .takeover, at: uptime, isolated: isolated)
            guard w.frame.geometry.isValid, w.display == row.display, w.member.canResize else {
                throw WorkspaceFailure.identity
            }
            eligible.append(w)
        }
        return eligible
    }
    public static func quit(
        _ baselines: [ManagedBaseline], live: [ManagedWindowID: LiveManagedWindow], current: WorkspaceSnapshot,
        usable: [String: SurfaceRect], uptime: Double, isolated: Bool
    ) -> [ManagedWindowID: ExitDisposition] {
        var result = [ManagedWindowID: ExitDisposition]()
        for entry in baselines {
            let id = entry.original.member.id
            result[id] = .needsAttention
            guard let w = live[id], w.member.id == id else { continue }
            do {
                if try current.preferences.excluded(id, bundle: w.bundle) {
                    result[id] = .leaveExcluded
                    continue
                }
                guard w == entry.lastConfirmed, w.ordinary else { continue }
                let row = try current.validate(w.workspace, action: .tile, at: uptime, isolated: isolated)
                guard row.display == w.display, let layout = row.layout, layout.members.contains(w.member) else { continue }
                if layout.userAdjusted {
                    guard let full = usable[w.display], let frame = try layout.frames(in: full)[id] else { continue }
                    result[id] = .restore(workspace: w.workspace, display: w.display, frame: frame)
                } else {
                    let original = entry.original
                    let origin = try current.validate(original.workspace, action: .tile, at: uptime, isolated: isolated)
                    if original.workspace != w.workspace || original.display != w.display {
                        _ = try current.validate(w.workspace, action: .moveMember, at: uptime, isolated: isolated)
                        _ = try current.validate(original.workspace, action: .moveMember, at: uptime, isolated: isolated)
                    }
                    guard origin.display == original.display, let area = usable[original.display],
                        original.frame.geometry.intersection(area.geometry) == original.frame.geometry
                    else { continue }
                    result[id] = .restore(workspace: original.workspace, display: original.display, frame: original.frame)
                }
            } catch { continue }
        }
        return result
    }
}

/// Deduplicate layout requests by the persistent area, members and user partition, excluding presentation.
public struct WorkAreaLayoutPlanner {
    private struct Input: Equatable { let area: SurfaceRect, layout: ManagedWindowTiler }
    private var last: [WorkspaceID: Input] = [:]
    public init() {}
    public mutating func update(area: DesktopWorkArea, layout: ManagedWindowTiler) throws -> [ManagedWindowID: SurfaceRect]?
    {
        let next = Input(area: area.ordinary, layout: layout)
        guard last[layout.workspace] != next else { return nil }
        let frames = try layout.frames(in: area.ordinary)
        last[layout.workspace] = next
        return frames
    }
}
