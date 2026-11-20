import AppKit
import OSLog
import SwiftUI

/// Each background view identifies a card in the actual nonactivating panel. The visible
/// SwiftUI button retains its normal accessibility action, context menu and scroll view.
struct SidebarCardPointer: NSViewRepresentable {
    let member: NativeSidebarMember
    let lifetime: UUID
    let current: () -> Bool
    let select: () -> Void
    let place: (SidebarPairDrop) -> Void
    let highlight: (Bool?) -> Void

    func makeNSView(context: Context) -> CardArea { CardArea() }
    func updateNSView(_ area: CardArea, context: Context) { area.card = self }

    final class CardArea: NSView {
        var card: SidebarCardPointer?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            (window as? EdgePanel)?.cardPointer.register(self)
        }
        func side(at point: NSPoint) -> Bool? {
            let local = convert(point, from: nil)
            guard !isHiddenOrHasHiddenAncestor, bounds.contains(local), visibleRect.contains(local) else { return nil }
            return SidebarPairDrop.left(at: local.x - bounds.minX, width: bounds.width)
        }
    }
}

@MainActor final class SidebarPanelPointer {
    private typealias Area = SidebarCardPointer.CardArea
    private let areas = NSHashTable<SidebarCardPointer.CardArea>.weakObjects()
    private var pressed: (member: NativeSidebarMember, lifetime: UUID, point: NSPoint, dragging: Bool)?
    private weak var highlighted: Area?
    private var highlightedSide: Bool?
    private static let log = Logger(subsystem: "com.holdsnow.nearpane.alpha", category: "SidebarPointer")

    func register(_ area: SidebarCardPointer.CardArea) { areas.add(area) }

    private func hit(in panel: NSWindow, at point: NSPoint) -> (Area, Bool)? {
        var result: (Area, Bool)?
        for area in areas.allObjects where area.window === panel {
            guard let side = area.side(at: point), area.card?.current() == true else { continue }
            guard result == nil else { return nil }
            result = (area, side)
        }
        return result
    }

    private func show(_ target: Area?, left: Bool? = nil) {
        guard highlighted !== target || highlightedSide != left else { return }
        if highlighted !== target { highlighted?.card?.highlight(nil) }
        highlighted = target
        highlightedSide = left
        target?.card?.highlight(left)
    }

    func cancel() { pressed = nil; show(nil) }

    /// Runs before NSPanel can consume a first click for activation or SwiftUI can turn
    /// a short drag into a button press. Right clicks, scrolling and other controls keep
    /// their ordinary event path. No synthetic input or window activation is involved.
    func receive(_ event: NSEvent, in panel: NSWindow) -> Bool {
        switch event.type {
        case .leftMouseDown:
            cancel()
            guard event.modifierFlags.intersection([.control, .option, .command, .shift]).isEmpty,
                  let (area, _) = hit(in: panel, at: event.locationInWindow),
                  let card = area.card else { return false }
            pressed = (card.member, card.lifetime, event.locationInWindow, false)
            Self.log.info("phase=cardDown")
            return true
        case .leftMouseDragged, .leftMouseUp:
            guard var held = pressed else { return false }
            let p = event.locationInWindow
            held.dragging = held.dragging || hypot(held.point.x - p.x, held.point.y - p.y) >= 5
            let target = hit(in: panel, at: p)
            let card = target?.0.card
            let same = held.member == card?.member && held.lifetime == card?.lifetime
            let eligible = held.dragging && !same && !held.member.selectionOnly && card?.member.selectionOnly == false &&
                card?.member.source == held.member.source && card?.member.key != held.member.key
            if event.type == .leftMouseDragged {
                pressed = held
                show(eligible ? target?.0 : nil, left: eligible ? target?.1 : nil)
            } else {
                cancel()
                if !held.dragging, same {
                    Self.log.info("phase=cardClick")
                    card?.select()
                } else if eligible, let card, let left = target?.1 {
                    Self.log.info("phase=cardDrop")
                    card.place(.init(dragged: held.member, target: card.member, draggedLifetime: held.lifetime,
                                     targetLifetime: card.lifetime, draggedOnLeft: left))
                }
            }
            return true
        case .keyDown where event.keyCode == 53:
            guard pressed != nil else { return false }
            cancel()
            return true
        default: return false
        }
    }
}
