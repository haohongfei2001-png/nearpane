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

@MainActor struct NativeSpaceMenuContents: View {
    let request: NativeSpaceMenu.Request
    let feed: CurrentDesktopWindows
    let navigation: NativeSidebarNavigation
    let allowed: @MainActor () -> Bool

    @ViewState private var probed: Bool?
    @ViewState private var highlighted: UUID?
    @FocusState private var listFocused: Bool

    private var menu: NativeSpaceMenu { .shared }
    private var currentRequest: Bool {
        menu.accepts(request, display: request.display, ownership: navigation.ownershipEpoch,
                     allowed: navigation.dispatchAvailable && allowed())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("本屏空间").font(.headline).accessibilityAddTraits(.isHeader)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                if let snapshot = feed.snapshot, let inventory = request.inventory(snapshot) {
                    VStack(alignment: .leading, spacing: 6) {
                        let canSwitch = !menu.selecting && inventory.stageOff && probed == true && navigation.canSwitch &&
                            currentRequest && CGPreflightPostEventAccess()
                        List(inventory.rows, selection: $highlighted) { row in
                            let label = HStack {
                                Text(row.title)
                                Spacer()
                                if row.isCurrent { Image(systemName: "checkmark").accessibilityHidden(true) }
                            }.contentShape(Rectangle())
                            Group {
                                if inventory.permits(row.destination, canSwitch: canSwitch) {
                                    Button { select(row, in: inventory) } label: { label }
                                        .buttonStyle(.plain)
                                } else {
                                    label.accessibilityElement(children: .combine)
                                }
                            }
                            .accessibilityLabel(row.isCurrent ? row.title + "，当前空间" : row.title)
                            .accessibilityAddTraits(row.isCurrent ? .isSelected : [])
                            .accessibilityIdentifier("native-space-row:\(request.display):\(row.destination.space)")
                            .tag(row.id)
                        }
                        .listStyle(.plain)
                        .frame(height: min(240, CGFloat(inventory.rows.count) * 28 + 8))
                        .focused($listFocused)
                        .onAppear { highlighted = inventory.source.uuid; listFocused = true }
                        .onKeyPress(.return) {
                            guard let row = inventory.rows.first(where: { $0.id == highlighted }),
                                  inventory.permits(row.destination, canSwitch: canSwitch) else { return .ignored }
                            select(row, in: inventory)
                            return .handled
                        }
                        if menu.selecting {
                            Text(navigation.issue ?? "正在确认目标空间…").font(.caption)
                        } else if inventory.build == "26A428" {
                            Text("此 macOS 版本尚未启用空间切换。").font(.caption)
                        } else if probed != nil && !canSwitch {
                            Text("目前无法切换本屏空间。").font(.caption)
                        } else if canSwitch && inventory.rows.contains(where: { !$0.isCurrent && !$0.isAdjacent }) {
                            Text("当前仅支持切换到相邻空间。").font(.caption)
                        }
                    }
                } else {
                    Text(probed == nil ? "正在读取本屏空间…" : "未能确认本屏空间。")
                }
            }
            HStack {
                Spacer()
                Button("关闭") { menu.close(request) }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .frame(width: 212)
        .padding(12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("native-space-menu")
        .accessibilityAction(.escape) { menu.close(request) }
        .onExitCommand { menu.close(request) }
        .onAppear { menu.appeared(request) }
        .onDisappear { menu.close(request) }
        .task(id: request.id) {
            guard currentRequest else { return }
            feed.changed()
            let capable = await navigation.probe(display: request.display)
            guard !Task.isCancelled, currentRequest else { return }
            probed = capable
        }
    }

    private func select(_ row: SpaceMenuInventory.Row, in inventory: SpaceMenuInventory) {
        guard currentRequest, probed == true,
              inventory.permits(row.destination, canSwitch: navigation.canSwitch && CGPreflightPostEventAccess()),
              menu.beginSelection(request) else { return }
        navigation.select(row.destination, member: nil, feed: feed, menuInventory: inventory, finished: { menu.close(request) }, allowed: {
            currentRequest && navigation.canSwitch && CGPreflightPostEventAccess()
        })
    }
}
