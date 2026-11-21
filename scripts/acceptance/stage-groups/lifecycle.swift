import AppKit
import NearpaneCore

private enum LifecycleFailure: Error { case inventory, processExit, siblingChanged, relaunch, membership }

/// Only the registered disposable owners read these stop files. The inspector never mutates another window.
@MainActor func verifyStageDeparture(root: URL, store: StageGroupStore, windows: [StageGroupWindow]) async throws {
    let output = root.appendingPathComponent("lifecycle.json")
    var receipt: [String: Any] = ["status": "UNKNOWN", "driver": "StageGroupStore", "productionWindowEngine": "NOT_RUN"]
    func save() throws { try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]).write(to: output, options: .atomic) }
    func owner(_ label: String) throws -> Owner {
        try JSONDecoder().decode(Owner.self, from: Data(contentsOf: root.appendingPathComponent(label + ".json")))
    }
    func frame(_ key: NativeSpaceWindow) -> CGRect? {
        guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, key.number) as? [[String: Any]], rows.count == 1,
              let row = rows.first, row[kCGWindowOwnerPID as String] as? Int32 == key.pid, row[kCGWindowIsOnscreen as String] as? Bool == true,
              let bounds = row[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }
    do {
        let a = try owner("a"), b = try owner("b")
        let siblings = windows.filter { $0.identity.pid == a.pid }
        guard siblings.count == 2, let old = windows.first(where: { $0.identity.pid == b.pid }),
              let group = store.groups(on: b.display).first(where: { $0.members.contains { $0.windowHint == old.identity } }),
              group.members.count == 2, try birth(b.pid) == b.birth else { throw LifecycleFailure.inventory }
        let before = siblings.compactMap { frame($0.identity) }
        guard before.count == 2, frame(old.identity) != nil else { throw LifecycleFailure.inventory }
        receipt["originalWindow"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old.identity))
        try save()
        try Data().write(to: root.appendingPathComponent("stop-owner-\(b.pid)"), options: .withoutOverwriting)
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline && (kill(b.pid, 0) == 0 || errno != ESRCH) {
            try await Task.sleep(for: .milliseconds(80))
        }
        let departed = try await StageWindowDeparture.exited(pid: b.pid, bound: store.boundWindows(of: b.pid))
        guard departed.count == 1, departed[0].window == old.identity, departed[0].lifetime == old.lifetime,
              try store.retire(departed, unowned: { _ in true }) == [old.identity] else { throw LifecycleFailure.processExit }
        receipt["departure"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(departed))
        let survivors = group.members.filter { $0.windowHint != old.identity }
        guard store.groups(on: b.display).first(where: { $0.id == group.id })?.members == survivors,
              siblings.compactMap({ frame($0.identity) }) == before else { throw LifecycleFailure.siblingChanged }
        try save()
        try Data().write(to: root.appendingPathComponent("lifecycle-retired"), options: .withoutOverwriting)
        let relaunchDeadline = ContinuousClock.now + .seconds(10)
        var replacement: Owner?
        while ContinuousClock.now < relaunchDeadline {
            if let candidate = try? owner("b"), candidate.birth != b.birth { replacement = candidate; break }
            try await Task.sleep(for: .milliseconds(80))
        }
        guard let replacement, replacement.identifier == b.identifier, replacement.display == b.display, replacement.onActiveSpace,
              replacement.numbers.count == 1, let n = replacement.numbers.first, try birth(replacement.pid) == replacement.birth,
              NSRunningApplication(processIdentifier: replacement.pid)?.bundleIdentifier == b.identifier else { throw LifecycleFailure.relaunch }
        let key = NativeSpaceWindow(pid: replacement.pid, birth: replacement.birth, number: n)
        guard let first = frame(key) else { throw LifecycleFailure.relaunch }
        try await Task.sleep(for: .milliseconds(100))
        guard frame(key) == first, siblings.compactMap({ frame($0.identity) }) == before else { throw LifecycleFailure.siblingChanged }
        let live = StageGroupWindow(display: b.display, identity: key, lifetime: UUID())
        try store.observe([live])
        guard let singleton = store.groups(on: b.display).first(where: { $0.members.map(\.windowHint) == [key] }),
              singleton.id != group.id, singleton.verifiedActive != true,
              store.groups(on: b.display).first(where: { $0.id == group.id })?.members == survivors,
              store.boundWindows(of: replacement.pid)[key] == live.lifetime else { throw LifecycleFailure.membership }
        receipt["replacementWindow"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(key))
        receipt["siblingWindowsUnchanged"] = siblings.count
        receipt["originalGroupPreserved"] = true
        receipt["replacementSingleton"] = singleton.id.uuidString
        receipt["status"] = "PASS"
        try save()
    } catch {
        receipt["status"] = "FAIL"
        receipt["reason"] = String(describing: error)
        try save()
        throw error
    }
}
