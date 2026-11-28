import AppKit
import OSLog
import SwiftUI

/// Each background view identifies a card in the actual nonactivating panel. The visible
/// SwiftUI button retains its normal accessibility action, context menu and scroll view.
struct SidebarCardPointer: NSViewRepresentable {
    struct StackPosition {
        let group, session: UUID
        let revision: UInt64
        let frontToBack: Int
    }
    let member: NativeSidebarMember
    let lifetime: UUID
    let current: () -> Bool
    let select: () -> Void
    let place: (SidebarPairDrop) -> Void
    let highlight: (Bool?) -> Void
    var prepare: () -> Void = {}
    var stack: StackPosition?
    var detach: (() -> Void)?

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
    private typealias Hit = (area: Area, left: Bool)
    private struct Press {
        let member: NativeSidebarMember
        let lifetime: UUID, group: UUID?, epoch: UUID
        let point: NSPoint, panelFrame: NSRect
        var dragging = false
    }
    private let areas = NSHashTable<SidebarCardPointer.CardArea>.weakObjects()
    private var pressed: Press?
    private var consumesPress = false
    private weak var highlighted: Area?
    private var highlightedSide: Bool?
    private static let log = Logger(subsystem: "com.holdsnow.nearpane.alpha", category: "SidebarPointer")

    func register(_ area: SidebarCardPointer.CardArea) { areas.add(area) }

    private func hits(in panel: NSWindow, at point: NSPoint) -> [Hit] {
        areas.allObjects.compactMap { area in
            guard area.window === panel, let side = area.side(at: point) else { return nil }
            return (area, side)
        }
    }

    private func top(_ hits: [Hit]) -> Hit? {
        guard let first = hits.first, let card = first.area.card else { return nil }
        if hits.count == 1 { return card.current() ? first : nil }
        guard let origin = card.stack, Set(hits.compactMap { $0.area.card?.member.key }).count == hits.count else { return nil }
        var positions = Set<Int>(), front: Hit?, best = Int.max
        for hit in hits {
            guard let other = hit.area.card, other.current(), let layer = other.stack, other.member.source == card.member.source,
                  layer.group == origin.group, layer.session == origin.session, layer.revision == origin.revision,
                  layer.frontToBack >= 0, positions.insert(layer.frontToBack).inserted else { return nil }
            if front == nil || layer.frontToBack < best { front = hit; best = layer.frontToBack }
        }
        return front
    }

    private func show(_ target: Area?, left: Bool? = nil) {
        guard highlighted !== target || highlightedSide != left else { return }
        if highlighted !== target { highlighted?.card?.highlight(nil) }
        highlighted = target
        highlightedSide = left
        target?.card?.highlight(left)
    }

    private func source(_ press: Press, in panel: NSWindow) -> SidebarCardPointer? {
        let matches = areas.allObjects.compactMap { area -> SidebarCardPointer? in
            guard area.window === panel, !area.isHiddenOrHasHiddenAncestor, let card = area.card,
                  card.member == press.member, card.lifetime == press.lifetime,
                  card.stack?.group == press.group, card.current() else { return nil }
            return card
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func droppedInWorkspace(_ point: NSPoint, source: Press, panel: NSWindow) -> Bool {
        let screenPoint = panel.convertPoint(toScreen: point)
        guard panel.frame == source.panelFrame, !panel.frame.insetBy(dx:-24,dy:-24).contains(screenPoint),
              let screen = panel.screen, screen.visibleFrame.contains(screenPoint),
              let number = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber,
              CGDisplayIsInMirrorSet(number.uint32Value) == 0,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
              (CFUUIDCreateString(nil,uuid) as String).caseInsensitiveCompare(source.member.source.display) == .orderedSame
        else { return false }
        return !NSApp.windows.contains { $0 !== panel && $0.isVisible && $0.frame.contains(screenPoint) }
    }

    func cancel() { consumesPress = false; pressed = nil; show(nil) }

    /// Runs before NSPanel can consume a first click for activation or SwiftUI can turn
    /// a short drag into a button press. Right clicks, scrolling and other controls keep
    /// their ordinary event path. No synthetic input or window activation is involved.
    func receive(_ event: NSEvent, in panel: NSWindow) -> Bool {
        switch event.type {
        case .leftMouseDown:
            cancel()
            guard event.modifierFlags.intersection([.control, .option, .command, .shift]).isEmpty else { return false }
            let candidates = hits(in:panel, at:event.locationInWindow)
            guard !candidates.isEmpty else { return false }
            consumesPress = true
            let navigation = NativeSidebarNavigation.shared
            guard navigation.dispatchAvailable, let card = top(candidates)?.area.card else { return true }
            pressed = Press(member:card.member,lifetime:card.lifetime,group:card.stack?.group,epoch:navigation.ownershipEpoch,
                            point:event.locationInWindow,panelFrame:panel.frame)
            card.prepare()
            Self.log.info("phase=cardDown")
            return true
        case .leftMouseDragged, .leftMouseUp:
            guard consumesPress else { return false }
            let navigation = NativeSidebarNavigation.shared
            guard var held = pressed, navigation.dispatchAvailable, navigation.ownershipEpoch == held.epoch,
                  event.modifierFlags.intersection([.control, .option, .command, .shift]).isEmpty else {
                pressed = nil
                if event.type == .leftMouseUp { cancel() } else { show(nil) }
                return true
            }
            let p = event.locationInWindow
            let draggedBeforeRelease = held.dragging
            held.dragging = held.dragging || hypot(held.point.x - p.x, held.point.y - p.y) >= 5
            let target = top(hits(in:panel,at:p))
            let card = target?.area.card
            let same = held.member == card?.member && held.lifetime == card?.lifetime && held.group == card?.stack?.group
            let eligible = held.dragging && !same && !held.member.selectionOnly && card?.member.selectionOnly == false &&
                card?.member.source == held.member.source && card?.member.key != held.member.key
            if event.type == .leftMouseDragged {
                pressed = held
                show(eligible ? target?.area : nil, left: eligible ? target?.left : nil)
            } else {
                cancel()
                if !held.dragging, same {
                    Self.log.info("phase=cardClick")
                    card?.select()
                } else if held.dragging, let original = source(held,in:panel) {
                    if eligible, let card, let left = target?.left {
                        Self.log.info("phase=cardDrop")
                        card.place(.init(dragged: held.member, target: card.member, draggedLifetime: held.lifetime,
                                         targetLifetime: card.lifetime, draggedOnLeft: left))
                    } else if draggedBeforeRelease, let detach = original.detach,
                              held.group != nil, !held.member.selectionOnly, droppedInWorkspace(p,source:held,panel:panel) {
                        detach()
                    }
                }
            }
            return true
        case .keyDown where event.keyCode == 53:
            guard consumesPress else { return false }
            cancel()
            return true
        case .scrollWheel, .beginGesture, .swipe, .magnify, .rotate:
            if consumesPress { pressed = nil; show(nil) }
            return false
        default: return false
        }
    }
}
