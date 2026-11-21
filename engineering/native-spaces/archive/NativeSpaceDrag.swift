import AppKit
import SwiftUI
import UniformTypeIdentifiers
import NearpaneCore

private typealias ViewState<T> = State<T>

/// Drag data stays inside this process. The item carries a one-use gesture ID,
/// never a serialised action or authority to control an arbitrary window.
@MainActor final class NativeSidebarDrag {
    static let type = UTType(exportedAs: "com.holdsnow.nearpane.space-window")
    private let navigation: NativeSidebarNavigation
    init(navigation: NativeSidebarNavigation = .shared) { self.navigation = navigation }
    private var gesture: (UUID, NativeSidebarMember, UUID, ContinuousClock.Instant, UUID)?

    var pendingMember: NativeSidebarMember? {
        guard let gesture, navigation.dispatchAvailable, navigation.ownershipEpoch == gesture.4, gesture.3 >= .now else { return nil }
        return gesture.1
    }

    func begin(_ member: NativeSidebarMember, feed: CurrentDesktopWindows?) -> NSItemProvider {
        guard navigation.dispatchAvailable, !member.selectionOnly, member.source.kind == .ordinary, let lifetime = feed?.lifetime(of: member.key) else { return NSItemProvider() }
        let token = UUID()
        gesture = (token, member, lifetime, .now.advanced(by: .seconds(20)), navigation.ownershipEpoch)
        let item = NSItemProvider()
        let data = Data(token.uuidString.utf8)
        item.registerDataRepresentation(forTypeIdentifier: Self.type.identifier, visibility: .ownProcess) { complete in
            complete(data, nil)
            return nil
        }
        return item
    }

    func receive(_ items: [NSItemProvider], accepts: (NativeSidebarMember) -> Bool = { _ in true }, action: @escaping @MainActor (NativeSidebarMember, UUID) -> Void) -> Bool {
        guard let gesture, navigation.dispatchAvailable, navigation.ownershipEpoch == gesture.4, gesture.3 >= .now, accepts(gesture.1), items.count == 1, let item = items.first,
              item.hasItemConformingToTypeIdentifier(Self.type.identifier) else { return false }
        let input = NativeSelectionPermit.inputCounters()
        item.loadDataRepresentation(forTypeIdentifier: Self.type.identifier) { [weak self] data, _ in
            guard let data, data == Data(gesture.0.uuidString.utf8) else { return }
            Task { @MainActor in
                guard let self, self.gesture?.0 == gesture.0, self.navigation.dispatchAvailable, self.navigation.ownershipEpoch == gesture.4,
                      gesture.3 >= .now, NativeSelectionPermit.inputCounters() == input else { return }
                self.gesture = nil
                action(gesture.1, gesture.2)
            }
        }
        return true
    }
}

struct NativeWindowDragSource: ViewModifier {
    let member: NativeSidebarMember?
    let drag: NativeSidebarDrag
    let feed: CurrentDesktopWindows?
    @ViewBuilder func body(content: Content) -> some View {
        if let member, !member.selectionOnly { content.onDrag { drag.begin(member, feed: feed) } } else { content }
    }
}

