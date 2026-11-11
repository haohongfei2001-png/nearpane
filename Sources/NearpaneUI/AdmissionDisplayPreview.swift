import NearpaneCore

/// Group only stable observations. A change of display or conflicting identity stays unlocated.
struct AdmissionDisplayPreview: Identifiable {
    let id: String
    let label: String
    let pairs: [AdmissionPair]
    var context: AdmissionContext

    static func groups(_ pairs: [AdmissionPair], screens: [ScreenGeometry], config: HostConfiguration,
                       scenario: AdmissionPlacement, ratio: Double, swap: Bool, custom: Bool,
                       recovery: Bool, exclusive: Bool?) -> [Self] {
        let resident = screens.first(where: { $0.id == config.preferredDisplayID }) ?? screens.first
        let repeatedNumbers = Dictionary(grouping: pairs, by: \.second.number).filter { $0.value.count > 1 }
        let processes = Dictionary(grouping: pairs, by: \.second.pid)
        let ambiguousProcesses = processes.filter { _, rows in
            let elements = rows.compactMap(\.second.element)
            return Set(rows.map(\.second.launch)).count != 1 || Set(rows.map(\.second.bundle)).count != 1 ||
                   Set(elements).count != elements.count
        }
        var byDisplay = [String: [AdmissionPair]]()
        for pair in pairs {
            let id = pair.second.display ?? ""
            let known = !id.isEmpty && pair.first.display == id && screens.filter { $0.id == id }.count == 1
                && repeatedNumbers[pair.second.number] == nil && ambiguousProcesses[pair.second.pid] == nil
            byDisplay[known ? id : "", default: []].append(pair)
        }
        func quartz(_ frame: SurfaceRect?) -> SurfaceRect {
            guard let frame, let menu = screens.first else { return .init(width: 0, height: 0) }
            return .init(x: frame.x, y: menu.frame.y + menu.frame.height - frame.y - frame.height,
                         width: frame.width, height: frame.height)
        }
        return (screens.map(\.id) + [""]).compactMap { id in
            guard let members = byDisplay.removeValue(forKey: id) else { return nil }
            let index = screens.firstIndex { $0.id == id }
            let geometry = index.map { screens[$0] }
            var settings = config.displays[id] ?? .init()
            var primary = !id.isEmpty && id == resident?.id
            if scenario != .current {
                settings.placement = scenario == .docked ? .docked : .floating
                if scenario == .floating { primary = false }
            }
            var context = AdmissionContext(display: id, screen: quartz(geometry?.frame), usable: quartz(geometry?.visibleFrame),
                                           primary: primary, settings: settings, edge: config.edge, preferences: config.workspaces,
                                           recoveryClear: recovery, exclusive: exclusive, ratio: custom ? ratio : 0.5, swapped: custom && swap)
            context.displayGeometry = geometry
            context.pairCustomized = custom
            context.hypothetical = scenario != .current || custom
            let label = index.map { "显示器 \($0 + 1)" } ?? "显示器归属未确认"
            return .init(id: id, label: label, pairs: members, context: context)
        }
    }
}
