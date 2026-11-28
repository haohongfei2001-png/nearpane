import AppKit
import CoreTransferable
import NearpaneCore
import SwiftUI
import UniformTypeIdentifiers

/// Only a nonce travels through the drag session. The window witnesses stay on the source display.
struct AppleStageDragTicket: Transferable {
    let nonce: UUID
    static let type = UTType(exportedAs: "com.holdsnow.nearpane.apple-stage-drag", conformingTo: .data)

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: type) { data in
            guard data.count == 36, let text = String(data: data, encoding: .ascii),
                  let nonce = UUID(uuidString: text) else { throw CocoaError(.fileReadCorruptFile) }
            return Self(nonce: nonce)
        }.visibility(.ownProcess)
    }

    func provider() -> NSItemProvider {
        let provider = NSItemProvider()
        let data = Data(nonce.uuidString.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: Self.type.identifier, visibility: .ownProcess) { reply in
            reply(data, nil)
            return nil
        }
        return provider
    }
}

@MainActor final class AppleNativeStageDrag {
    typealias Group = AppleNativeStages.Group
    struct Scope: Equatable {
        let session: UUID, display: String, desktop: UUID, record: String, topology: String
    }
    private struct Source {
        let ticket: AppleStageDragTicket, group: Group, scope: Scope, intent: UUID
        let appearances: [UUID], expiry: ContinuousClock.Instant
    }
    private var active: Source?

    func cancel() { active = nil }

    func begin(_ group: Group, scope: Scope, intent: UUID, groups: [Group],
               lifetime: (DesktopWindowKey) -> UUID?, now: ContinuousClock.Instant = .now) -> AppleStageDragTicket? {
        cancel()
        let appearances = group.members.compactMap(lifetime)
        guard !group.members.isEmpty, appearances.count == group.members.count,
              groups.contains(group) else { return nil }
        let ticket = AppleStageDragTicket(nonce: UUID())
        active = Source(ticket: ticket, group: group, scope: scope, intent: intent,
                        appearances: appearances, expiry: now.advanced(by: .seconds(60)))
        return ticket
    }

    func consume(_ ticket: AppleStageDragTicket, into destination: Group, scope: Scope, intent: UUID,
                 groups: [Group], lifetime: (DesktopWindowKey) -> UUID?,
                 now: ContinuousClock.Instant = .now) -> Group? {
        guard let source = active, source.ticket.nonce == ticket.nonce else { return nil }
        cancel()
        guard now < source.expiry, intent == source.intent, scope == source.scope,
              source.group.id != destination.id, !destination.members.isEmpty,
              Set(source.group.members).isDisjoint(with: destination.members),
              groups.contains(source.group), groups.contains(destination),
              source.group.members.compactMap(lifetime) == source.appearances,
              destination.members.allSatisfy({ lifetime($0) != nil }) else { return nil }
        return source.group
    }
}

struct AppleStageDropTarget: ViewModifier {
    let enabled: Bool
    let begin: @MainActor () -> NSItemProvider
    let drop: @MainActor (AppleStageDragTicket) -> Bool

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.onDrag(begin)
                .dropDestination(for: AppleStageDragTicket.self) { items, _ in
                    guard items.count == 1, let ticket = items.first else { return false }
                    return drop(ticket)
                }
        } else {
            content
        }
    }
}
