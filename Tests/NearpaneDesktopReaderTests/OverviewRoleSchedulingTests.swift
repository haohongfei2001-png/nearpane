import Foundation
import Testing
import NearpaneCore
import WindowGeometryCore
@testable import NearpaneDesktopReader

struct OverviewRoleSchedulingTests {
    @Test func slowOwnerCannotExhaustAnotherCurrentOwnersReadTime() {
        let targets = (10...13).map { OverviewWindowRole.Target(pid: Int32($0), numbers: [UInt32($0)]) }
        var now = 0.0, visited: [Int32] = []
        let result = OverviewWindowRole.schedule(targets, deadline: 0.8, now: { now }) { target, limit in
            visited.append(target.pid)
            let finish = now + (target.pid == 10 ? 1.0 : 0.03)
            now = min(finish, limit)
            return finish <= limit ? .init() : nil
        }
        #expect(visited == [10, 11, 12, 13])
        #expect(Set(result.keys) == [11, 12, 13])
        #expect(now <= 0.8)
    }

    @Test func unreadableAndDuplicateSiblingsDoNotEraseOtherExactWindowRoles() {
        var now = 0.0, detailed: [Int] = []
        let numbers: [UInt32?] = [nil, 20, 21, 22, 21, 23]
        let owner = OverviewWindowRole.readRows(Array(numbers.indices), wanted: [20,21,23], deadline: 0.6, now: { now },
            number: { i, limit in
                if i == 0 { now = limit }
                else if i == 4 { now = limit + 0.001 } // Even a late duplicate revokes the earlier match.
                else { now += 0.002 }
                return numbers[i]
            }, role: { i, _ in
                detailed.append(i)
                return .init(ordinary: true, minimized: false, fullscreen: false)
            })
        #expect(!owner.everyNumberKnown && owner.allRolesRead)
        #expect(detailed == [1,2,5])  // No role query for the other desktop's window or the duplicate.
        #expect(owner.windows[20]?.ordinary == true && owner.windows[23]?.ordinary == true)
        #expect(owner.windows[21]?.ordinary == false && owner.windows[22] == nil)
        #expect(now < 0.6)
    }

    @Test func onlyRequestRoleDetailsForWindowsWhichCouldBeDisplayed() {
        let roles: [(pid: Int32, id: UInt32, space: String?, onscreen: Bool)] = [
            (41, 11, "remote", true), (42, 12, "remote", true), (42, 13, "current", true),
            (43, 14, nil, false), (44, 15, "current", false), (45, 16, "current", true)]
        var list = Reader.List()
        for (z, w) in roles.enumerated() {
            list.windows.append(.init(process: .init(pid: w.pid, launchEpochMicroseconds: 1),
                windowID: w.id, title: nil, frame: Rect(10,10,100,100), isOnscreen: w.onscreen, frontToBackIndex: z))
        }
        list.unhiddenOwners = [41,42,43,44]  // 45 is an application explicitly hidden by its owner.
        list.orderedAcrossSpaces = [11,12,13,14,15,16]
        let memberships = Dictionary(uniqueKeysWithValues: roles.map { ($0.id, $0.space.map { WindowMembership.known(recordIDs: [$0]) } ?? .unknown) })
        let planned = Reader.roleTargets(list, active: [13,16], currentIDs: ["current"], memberships: memberships)
        #expect(planned == [.init(pid: 42, numbers: [13]), .init(pid: 44, numbers: [15])])
        let publicOnly = Reader.roleTargets(list, active: [13,16], currentIDs: nil, memberships: [:])
        #expect(publicOnly == [.init(pid: 42, numbers: [13])])
    }
}
