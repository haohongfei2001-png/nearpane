import Foundation
import NearpaneCore
import Testing
@testable import NearpaneUI

@MainActor struct AppleStageMemberCycleTests {
    @Test func repeatClicksCycleOnlyTheSameApplicationsConfirmedMembersInStableOrder() {
        typealias Group = AppleNativeStages.Group
        let a = DesktopWindowKey(pid: 20, birth: 12, number: 7), b = DesktopWindowKey(pid: 20, birth: 12, number: 8)
        let c = DesktopWindowKey(pid: 20, birth: 12, number: 9), other = DesktopWindowKey(pid: 21, birth: 13, number: 10)
        let original = Group(id: "group", current: true, members: [a, other, b, c])
        let raised = Group(id: "group", current: true, members: [b, c, other, a])
        let first = AppleStageMemberCycle(group: original, selected: a, previous: nil, focused: { true })
        #expect(first.next(in: original, explicit: nil, oneAtATime: true, completingPrevious: false) == b)
        let second = AppleStageMemberCycle(group: raised, selected: b, previous: first, focused: { true })
        #expect(second.next(in: raised, explicit: nil, oneAtATime: true, completingPrevious: false) == c)
        let third = AppleStageMemberCycle(group: original, selected: c, previous: second, focused: { true })
        #expect(third.next(in: original, explicit: nil, oneAtATime: true, completingPrevious: false) == a)
        #expect(first.next(in: original, explicit: c, oneAtATime: true, completingPrevious: false) == nil)
        #expect(first.next(in: original, explicit: nil, oneAtATime: false, completingPrevious: false) == nil)
        let inactive = Group(id: original.id, current: false, members: original.members)
        #expect(first.next(in: inactive, explicit: nil, oneAtATime: true, completingPrevious: false) == nil)
        #expect(first.next(in: inactive, explicit: nil, oneAtATime: true, completingPrevious: true) == b)
        let otherStage = Group(id: "different", current: true, members: [a, b])
        #expect(first.next(in: otherStage, explicit: nil, oneAtATime: true, completingPrevious: false) == nil)
        let missing = Group(id: original.id, current: true, members: [a])
        #expect(first.next(in: missing, explicit: nil, oneAtATime: true, completingPrevious: false) == nil)
        let one = AppleStageMemberCycle(group: missing, selected: a, previous: nil, focused: { true })
        #expect(one.next(in: missing, explicit: nil, oneAtATime: true, completingPrevious: false) == nil)
        let changed = AppleStageMemberCycle(group: original, selected: a, previous: first, focused: { false })
        #expect(changed.next(in: original, explicit: nil, oneAtATime: true, completingPrevious: false) == nil)
    }

    @Test func onlyExplicitOneAtATimeEnablesCycling() {
        #expect(AppleStageMemberCycle.oneAtATime(NSNumber(value: 0)))
        #expect(!AppleStageMemberCycle.oneAtATime(NSNumber(value: 1)))
        #expect(!AppleStageMemberCycle.oneAtATime(nil))
        #expect(!AppleStageMemberCycle.oneAtATime("0" as NSString))
    }
}
