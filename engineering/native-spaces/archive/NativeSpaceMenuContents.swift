import SwiftUI
import NearpaneCore

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
