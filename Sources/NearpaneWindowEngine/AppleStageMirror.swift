import AppKit
import ApplicationServices
import CNearpaneWindowEngine
import Foundation

/// A transient interpretation of WindowManager for one physical display and one native desktop.
/// Only window numbers, process IDs and rectangles cross into Rust. The caller owns window identity.
package final class AppleStageMirror {
    package struct Stage: Equatable {
        package let current: Bool
        package let remembered: Bool
        package let members: [UInt32]
    }
    package struct Reading {
        package let stages: [Stage]
        package let settled: Bool
        package let contradictory: Bool
        package let stripShown: Bool?
    }

    let handle: UInt64
    private let scope: NPAppleMirrorScope

    package init?(display: UUID, space: UInt64) {
        var scope = NPAppleMirrorScope()
        scope.size = UInt32(MemoryLayout.size(ofValue: scope))
        scope.version = UInt32(NP_APPLE_MIRROR_ABI)
        scope.display_uuid = display.uuid
        scope.native_space_id = space
        var handle: UInt64 = 0
        guard np_apple_mirror_create(&scope, &handle) == NP_APPLE_MIRROR_OK else { return nil }
        self.scope = scope
        self.handle = handle
    }

    deinit { _ = np_apple_mirror_destroy(handle) }

    package func read(_ system: AppleStageSystemRead, managed: [UInt32], screen: CGRect,
                      transition: Bool = false) -> Reading? {
        let ax = system.strip(on: screen)
        let axMembers = ax?.enumerated().flatMap { index, item in
            item.members.map { NPAppleAXMember(item: UInt32(index), window: $0, frame: NPAppleRect(item.frame)) }
        } ?? []
        guard managed.count <= NP_APPLE_MAX_MANAGED, axMembers.count <= NP_APPLE_MAX_AX_MEMBERS else { return nil }
        var input = NPAppleMirrorInput()
        input.size = UInt32(MemoryLayout.size(ofValue: input))
        input.version = scope.version
        input.scope = scope
        input.sample_time_ns = system.sampleTime
        input.display_frame = NPAppleRect(screen)
        input.manager_pid = system.manager
        input.ax_available = ax == nil ? 0 : 1
        input.transition_began = transition ? 1 : 0
        input.listed_count = UInt32(system.listed.count)
        input.managed_count = UInt32(managed.count)
        input.ax_count = UInt32(axMembers.count)
        var result = NPAppleMirrorResult()
        result.size = UInt32(MemoryLayout.size(ofValue: result))
        result.version = scope.version
        var output = Array(repeating: NPAppleMirrorMember(), count: managed.count)
        let capacity = UInt32(output.count)
        let rc = system.listed.withUnsafeBufferPointer { rows in
            managed.withUnsafeBufferPointer { keys in
                axMembers.withUnsafeBufferPointer { observed in
                    input.listed = rows.baseAddress
                    input.managed = keys.baseAddress
                    input.ax_members = observed.baseAddress
                    return np_apple_mirror_read_v1(handle, &input, &output, capacity, &result)
                }
            }
        }
        guard rc == NP_APPLE_MIRROR_OK, result.member_count <= capacity else { return nil }
        let groups = Dictionary(grouping: output.prefix(Int(result.member_count)), by: \.ordinal)
        let ranks = Dictionary(system.listed.enumerated().map { ($0.element.window, $0.offset) },
                               uniquingKeysWith: min)
        let stages = groups.keys.sorted().compactMap { ordinal -> Stage? in
            guard let rows = groups[ordinal], let first = rows.first else { return nil }
            let members = rows.map(\.window).sorted { (ranks[$0] ?? .max, $0) < (ranks[$1] ?? .max, $1) }
            return Stage(current: first.role == NP_APPLE_CURRENT, remembered: first.role == NP_APPLE_REMEMBERED,
                         members: members)
        }
        return Reading(stages: stages, settled: result.settled == 1, contradictory: result.disagreement == 1 && result.trusted_ax == 0,
                       stripShown: result.strip_shown < 0 ? nil : result.strip_shown == 1)
    }
}

extension NPAppleRect {
    init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }
}
