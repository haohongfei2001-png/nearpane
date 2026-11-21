import Foundation
import NearpaneCore

/// An explicit sidebar grouping is bound to one observed window lifetime per member.
@MainActor @Observable final class ExplicitWindowGroups {
    struct Group: Identifiable {
        let id: UUID
        let space: UUID
        var members: [DesktopWindowKey: UUID]
    }

    private(set) var records: [Group] = []

    func join(_ a: DesktopWindowKey, _ b: DesktopWindowKey, space: UUID, lifetimes: [DesktopWindowKey: UUID]) {
        guard a != b, let first = lifetimes[a], let second = lifetimes[b] else { return }
        let matching = records.filter { $0.space == space && ($0.members[a] == first || $0.members[b] == second) }
        var members = [a: first, b: second]
        for record in matching {
            for (key, birth) in record.members where lifetimes[key] == birth { members[key] = birth }
        }
        records.removeAll { record in matching.contains(where: { $0.id == record.id }) }
        records.append(.init(id: matching.first?.id ?? UUID(), space: space, members: members))
    }

    func dissolve(_ id: UUID) { records.removeAll { $0.id == id } }

    func reconcile(lifetimes: [DesktopWindowKey: UUID], departed: (DesktopWindowKey, UUID) -> Bool) {
        for index in records.indices.reversed() {
            let record = records[index]
            let remaining = record.members.filter { lifetimes[$0.key] == $0.value && !departed($0.key, record.space) }
            if remaining.count < 2 { records.remove(at: index) }
            else if remaining.count != record.members.count { records[index].members = remaining }
        }
    }

    func visible(space: UUID, members: Set<DesktopWindowKey>) -> [DesktopWindowKey: Group] {
        var result = [DesktopWindowKey: Group]()
        for record in records where record.space == space && members.isSuperset(of: record.members.keys) {
            for key in record.members.keys { result[key] = record }
        }
        return result
    }
}
