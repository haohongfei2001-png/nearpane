import SwiftUI
import NearpaneCore

private typealias ViewState<T> = State<T>

/// A request from the status menu belongs to one presentation of one physical display.
@MainActor @Observable public final class NativeSpaceMenu {
    struct Request: Equatable, Identifiable {
        let id = UUID()
        private let openedAt = ProcessInfo.processInfo.systemUptime
        let display: String
        let ownership: UUID

        func inventory(_ snapshot: DesktopSnapshot) -> SpaceMenuInventory? {
            guard let evidence = snapshot.native, evidence.beganUptime >= openedAt else { return nil }
            return SpaceMenuInventory(snapshot, display: display)
        }
    }

    static let shared = NativeSpaceMenu()
    private(set) var active: Request?
    private(set) var selecting = false
    @ObservationIgnored private var expiry: Task<Void, Never>?

    public static func request(on display: String) {
        let lane = NativeSidebarNavigation.shared
        guard lane.dispatchAvailable, WindowContentPreview.sessionAvailable(), UUID(uuidString: display) != nil else { return }
        shared.open(on: display, ownership: lane.ownershipEpoch)
    }

    func open(on display: String, ownership: UUID) {
        let request = Request(display: display, ownership: ownership)
        expiry?.cancel()
        selecting = false
        active = request
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            self?.close(request)
        }
    }

    func appeared(_ request: Request) {
        guard active == request else { return }
        expiry?.cancel()
        expiry = nil
    }

    func close(_ request: Request) {
        guard active == request else { return }
        expiry?.cancel()
        expiry = nil
        selecting = false
        active = nil
    }

    func beginSelection(_ request: Request) -> Bool {
        guard active == request, !selecting else { return false }
        selecting = true
        return true
    }

    func accepts(_ request: Request, display: String?, ownership: UUID, allowed: Bool) -> Bool {
        allowed && active == request && request.display == display && request.ownership == ownership
    }
}

struct SpaceMenuInventory: Equatable {
    struct Row: Identifiable, Equatable {
        let destination: NativeSidebarDestination
        let title: String
        let isCurrent: Bool
        let isAdjacent: Bool
        var id: UUID { destination.uuid }
    }

    private struct Identity: Equatable {
        let id: String
        let ordinary, fullscreen: UUID?
    }
    private let physicalOrder: [Identity]
    let source: NativeSidebarDestination
    let rows: [Row]
    let build: String
    let stageOff: Bool

    init?(_ snapshot: DesktopSnapshot, display: String, now: Date = .now, uptime: Double = ProcessInfo.processInfo.systemUptime) {
        guard snapshot.native?.stageManagerEnabled != true,
              let catalog = NativeSpaceCatalog(snapshot, displayID: display, now: now, uptime: uptime),
              let scope = snapshot.scopes.first(where: { $0.displayID == display }),
              let current = scope.records.firstIndex(where: \.isCurrent),
              let currentRow = catalog.rows.first(where: { $0.record.isCurrent }),
              let source = NativeSidebarDestination(currentRow, in: catalog) else { return nil }
        let catalogRows = Dictionary(uniqueKeysWithValues: catalog.rows.map { ($0.id, $0) })
        var desktops = 0, fullscreen = 0
        rows = scope.records.enumerated().compactMap { index, record in
            let title: String
            switch record.nativeKind {
            case .ordinary: desktops += 1; title = "桌面 \(desktops)"
            case .fullscreen: fullscreen += 1; title = "全屏空间 \(fullscreen)"
            case nil: return nil
            }
            guard let row = catalogRows[record.id], let target = NativeSidebarDestination(row, in: catalog) else { return nil }
            return Row(destination: target, title: title, isCurrent: record.isCurrent, isAdjacent: abs(index - current) == 1)
        }
        self.source = source
        physicalOrder = scope.records.map { Identity(id: $0.id, ordinary: $0.ordinaryUUID, fullscreen: $0.fullscreenUUID) }
        build = snapshot.sourceBuild
        stageOff = snapshot.native?.stageManagerEnabled == false
    }

    func permits(_ target: NativeSidebarDestination, canSwitch: Bool) -> Bool {
        canSwitch && stageOff && build != "26A428" && rows.contains { $0.destination == target && $0.isAdjacent && !$0.isCurrent }
    }

    /// Called after the action lane obtains its own fresh snapshot, before constructing the command.
    func stillOffers(_ target: NativeSidebarDestination, in snapshot: DesktopSnapshot) -> Bool {
        guard let live = Self(snapshot, display: source.display) else { return false }
        return live == self && live.permits(target, canSwitch: true)
    }
}
