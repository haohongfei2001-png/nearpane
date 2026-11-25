import Foundation
import NearpaneCore

/// The native strip can omit an application's other documents. Only witnesses in
/// the same system group participate; their initial order survives subsequent raises.
@MainActor struct AppleStageMemberCycle {
    typealias Group = AppleNativeStages.Group
    let groupID: String
    let order: [DesktopWindowKey]
    let selected: DesktopWindowKey
    let focused: @MainActor () -> Bool

    init(group: Group, selected: DesktopWindowKey, previous: Self?, focused: @escaping @MainActor () -> Bool) {
        groupID = group.id
        if let previous, previous.matches(group) { order = previous.order }
        else { order = group.members }
        self.selected = selected
        self.focused = focused
    }

    static func oneAtATime() -> Bool {
        oneAtATime(CFPreferencesCopyAppValue("AppWindowGroupingBehavior" as CFString, "com.apple.WindowManager" as CFString))
    }

    static func oneAtATime(_ setting: CFPropertyList?) -> Bool {
        guard let number = setting as? NSNumber else { return false }
        // Native settings use 0 for One at a Time and 1 (also the default) for All at Once.
        return number.compare(NSNumber(value: 0)) == .orderedSame
    }

    func matches(_ group: Group) -> Bool { group.id == groupID && Set(order) == Set(group.members) }

    func next(in group: Group, explicit: DesktopWindowKey?, oneAtATime: Bool, completingPrevious: Bool) -> DesktopWindowKey? {
        guard explicit == nil, oneAtATime, matches(group), completingPrevious || (group.current && focused()) else { return nil }
        let siblings = order.filter { $0.pid == selected.pid && $0.birth == selected.birth }
        guard siblings.count > 1, let index = siblings.firstIndex(of: selected) else { return nil }
        return siblings[(index + 1) % siblings.count]
    }
}
