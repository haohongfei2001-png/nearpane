import Foundation
import NearpaneCore

/// Lab observations only. A matching checkpoint cannot authorize an action or
/// establish how a window got there. The controller must retain the NS/AX objects.
struct EnrolledMovePlan: Equatable, Codable {
    let run, operation: UUID
    let pid: Int32, launch: UInt64
    let display, source, target: String
    let sourceAnchor, targetAnchor, member: UInt32
    let destinationFrame: SurfaceRect

    var numbers: [UInt32] { [sourceAnchor, targetAnchor, member] }
    var valid: Bool {
        pid > 1 && launch > 0 && !display.isEmpty && !source.isEmpty && !target.isEmpty && source != target
            && Set(numbers).count == 3 && !numbers.contains(0) && destinationFrame.geometry.isValid
    }
}

enum EnrolledMoveCheckpoint: String, Codable { case before, atDestination, backAtSource }

struct EnrolledMoveReadback: Codable, Equatable {
    let plan: EnrolledMovePlan
    let build: String, uptime: Double
    let route: NativeRouteEvidence
    let frames: [UInt32: SurfaceRect], visible: Set<UInt32>

    private func occupies(_ record: String) -> Bool {
        guard plan.valid, !build.isEmpty, uptime.isFinite, uptime > 0, !route.topology.isEmpty,
              route.currents.count == 2, route.currents[plan.display] == record,
              Set(route.currents.keys) == Set(route.orders.keys),
              route.currents.allSatisfy({ route.orders[$0.key]?.contains($0.value) == true }),
              let order = route.orders[plan.display], Set(order).count == order.count,
              let a = order.firstIndex(of: plan.source), let b = order.firstIndex(of: plan.target), abs(a-b) == 1,
              Set(frames.keys) == Set(plan.numbers), frames.values.allSatisfy({ $0.geometry.isValid }) else { return false }
        let anchor = record == plan.source ? plan.sourceAnchor : plan.targetAnchor
        return visible == [anchor, plan.member]
            && route.membership == [plan.sourceAnchor: plan.source, plan.targetAnchor: plan.target, plan.member: record]
    }

    func verifies(_ checkpoint: EnrolledMoveCheckpoint, original: Self?) -> Bool {
        if checkpoint == .before { return original == nil && occupies(plan.source) }
        guard let original, original.plan == plan, original.occupies(plan.source),
              original.uptime < uptime, original.build == build, original.route.topology == route.topology,
              original.route.orders == route.orders,
              frames[plan.sourceAnchor] == original.frames[plan.sourceAnchor],
              frames[plan.targetAnchor] == original.frames[plan.targetAnchor] else { return false }
        switch checkpoint {
        case .atDestination:
            var expected = original.route.currents
            expected[plan.display] = plan.target
            return route.currents == expected && occupies(plan.target) && frames[plan.member] == plan.destinationFrame
        case .backAtSource:
            return occupies(plan.source) && route == original.route && frames == original.frames
        case .before:
            return false
        }
    }
}

#if NEARPANE_ISOLATED_GUI_LAB
import AppKit
import Darwin

struct EnrolledMoveRequest: Decodable {
    let plan: EnrolledMovePlan, checkpoint: EnrolledMoveCheckpoint
    let original: EnrolledMoveReadback?

    struct Reply: Encodable {
        let checkpoint: EnrolledMoveCheckpoint, matchesCheckpoint: Bool, observation: EnrolledMoveReadback
    }

    @MainActor func observe() throws -> Reply {
        guard plan.valid, plan.pid == getppid(), AXIsProcessTrusted() else { throw DesktopActionError.unsupported }
        let app = AXUIElementCreateApplication(plan.pid)
        guard AXUIElementSetMessagingTimeout(app, 0.12) == .success else { throw DesktopActionError.unsupported }
        // A copied test reader cannot enumerate a different app merely by supplying its bundle ID.
        let reader = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        let expected = reader.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacOS/NearpaneSpaceWitness").path
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(plan.pid, &path, UInt32(path.count)) > 0,
              String(decoding: path.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self) == expected
        else { throw DesktopActionError.unsupported }
        func readWindows() throws -> (frames: [UInt32: SurfaceRect], visible: Set<UInt32>, elements: [AXUIElement]) {
            var owner = proc_bsdinfo()
            let size = Int32(MemoryLayout.size(ofValue: owner))
            guard getppid() == plan.pid, proc_pidinfo(plan.pid, PROC_PIDTBSDINFO, 0, &owner, size) == size,
                  owner.pbi_pid == UInt32(plan.pid), owner.pbi_uid == getuid(),
                  owner.pbi_start_tvsec * 1_000_000 + owner.pbi_start_tvusec == plan.launch else {
                throw DesktopActionError.unsupported
            }
            let topology = try Topology()
            guard topology.separateSpaces, topology.displays.count == 2, topology.geometry.primary.displayID != plan.display,
                  let screen = topology.displays.first(where: { $0.id == plan.display })?.frame.geometry,
                  screen.intersection(plan.destinationFrame.geometry) == plan.destinationFrame.geometry
            else { throw DesktopActionError.unsupported }
            var list: CFArray?
            guard AXUIElementCopyAttributeValues(app, kAXWindowsAttribute as CFString, 0, 4, &list) == .success,
                  let windows = list as? [AXUIElement], windows.count == 3 else { throw DesktopActionError.unsupported }
            var frames = [UInt32: SurfaceRect](), visible = Set<UInt32>(), elements = [AXUIElement]()
            for (number, label) in zip(plan.numbers, ["A", "B", "member"]) {
                let matches = windows.filter { AdmissionAXRead.windowNumber($0) == number }
                guard matches.count == 1, let element = matches.first,
                      AdmissionAXRead.value(element, kAXIdentifierAttribute) as? String == plan.run.uuidString + "/" + label,
                      AdmissionAXRead.value(element, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
                      AdmissionAXRead.value(element, kAXMinimizedAttribute) as? Bool == false,
                      AdmissionAXRead.value(element, "AXFullScreen") as? Bool == false,
                      let ax = AdmissionAXRead.frame(element), ax.geometry.isValid, screen.intersection(ax.geometry) == ax.geometry,
                      let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, number) as? [[String: Any]],
                      rows.count == 1, let row = rows.first, row[kCGWindowOwnerPID as String] as? Int32 == plan.pid,
                      row[kCGWindowNumber as String] as? UInt32 == number, row[kCGWindowLayer as String] as? Int == 0,
                      let bounds = row[kCGWindowBounds as String] as? NSDictionary, let cg = CGRect(dictionaryRepresentation: bounds),
                      SurfaceRect(x: cg.minX, y: cg.minY, width: cg.width, height: cg.height) == ax
                else { throw DesktopActionError.unsupported }
                // WindowServer omits kCGWindowIsOnscreen for an off-screen window.
                let shown = row[kCGWindowIsOnscreen as String]
                guard shown == nil || (shown as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() }) == true
                else { throw DesktopActionError.unsupported }
                if shown as? Bool == true {
                    guard let alpha = row[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue > 0
                    else { throw DesktopActionError.unsupported }
                    visible.insert(number)
                }
                frames[number] = ax
                elements.append(element)
            }
            return (frames, visible, elements)
        }
        let first = try readWindows()
        let route = try EnrolledRoute.sample(display: plan.display, numbers: plan.numbers)
        let last = try readWindows()
        guard first.frames == last.frames, first.visible == last.visible,
              zip(first.elements, last.elements).allSatisfy({ CFEqual($0.0, $0.1) }) else { throw DesktopActionError.unsupported }
        let result = EnrolledMoveReadback(plan: plan, build: ProcessInfo.processInfo.operatingSystemVersionString,
            uptime: ProcessInfo.processInfo.systemUptime, route: route, frames: last.frames, visible: last.visible)
        return Reply(checkpoint: checkpoint, matchesCheckpoint: result.verifies(checkpoint, original: original), observation: result)
    }
}
#endif
