#if NEARPANE_P0_DIAGNOSTIC
import AppKit
import NearpaneCore

/// A visible signed Host consumes a signed diagnostic request. Only previously witnessed real
/// catalog members are eligible; there is no card or system input in the observer process.
@MainActor final class P0HostDiagnostic {
    private static var addressed = Set<UUID>()

    func listen(_ lease: P0DiagnosticLease, display: String, feed: CurrentDesktopWindows,
                navigation: NativeSidebarNavigation, allowed: @escaping @MainActor () -> Bool) async {
        while !Task.isCancelled, allowed() {
            if FileManager.default.fileExists(atPath:lease.file.path),
               let grant = try? lease.read(host:getpid()), UUID(uuidString:display) == grant.topology.display,
               Self.addressed.insert(grant.operation).inserted {
                await submit(grant,lease:lease,display:display,feed:feed,navigation:navigation,allowed:allowed)
                return
            }
            do { try await Task.sleep(for:.milliseconds(120)) } catch { return }
        }
    }

    private func submit(_ grant: P0DiagnosticGrant, lease: P0DiagnosticLease, display: String, feed: CurrentDesktopWindows,
                        navigation: NativeSidebarNavigation, allowed: @escaping @MainActor () -> Bool) async {
        func write(_ state: String) {
            let row: [String:Any] = ["scope":"DIAGNOSTIC_ONLY","operation":grant.operation.uuidString,"state":state,
                                     "hostPID":getpid(),"uptime":ProcessInfo.processInfo.systemUptime]
            if let data = try? JSONSerialization.data(withJSONObject:row) {
                try? data.write(to:lease.home.appendingPathComponent("p0-host-one-shot-response.json"),options:.atomic)
            }
        }
        guard allowed(), !Task.isCancelled, let read = await feed.readNow(),
              let map = NativeSpaceCatalog(read,displayID:display,now:.now,uptime:ProcessInfo.processInfo.systemUptime),
              map.current.id == String(grant.topology.current), map.current.nativeUUID == grant.sourceSpace?.uuid,
              let section = SidebarBackgroundWindows.sections(in:map).first(where:{
                  $0.destination.space == String(grant.target) && $0.destination.uuid == grant.targetSpace?.uuid
              }) else { write("source-or-real-background-catalog-unavailable"); return }
        let targets = section.windows.compactMap { NativeSidebarMember($0,source:section.destination) }.filter {
            $0.key.pid == grant.targetWindow.pid && $0.key.birth == grant.targetWindow.birth && $0.key.number == grant.targetWindow.number
        }
        guard targets.count == 1, let member = targets.first, let token = member.originalWindow, let location = member.location,
              feed.tracks(token,at:location), let current = map.rows.first(where: { $0.id == map.current.id }),
              current.windows.contains(where:{ $0.metadata?.pid == grant.sourceWindow.pid &&
                  $0.metadata?.launchMicroseconds == grant.sourceWindow.birth && $0.metadata?.number == grant.sourceWindow.number }),
              allowed(), !Task.isCancelled, (try? lease.read(host:getpid())) == grant else {
            write("original-window-or-current-fixture-unavailable"); return
        }
        write("accepted-by-installed-host")
        navigation.select(section.destination,member:member,feed:feed,operation:grant.operation,allowed:allowed)
    }
}
#endif
