import SwiftUI
import NearpaneCore
import NearpaneOrdinaryWindowRuntime

/// Read-only AX identity for an already displayed ordinary window. This object has no action methods.
@MainActor final class StagePictureOriginal {
    private let key: DesktopWindowKey, element: AXUIElement
    private let forCard: Bool
    private var verifiedAppearance: UUID?
    private static func exact(_ key: DesktopWindowKey, forCard: Bool) -> AXUIElement? {
        guard AXIsProcessTrusted(), let list = try? windows(key.pid) else { return nil }
        let same = list.filter { number($0) == key.number }
        guard same.count == 1, let w = same.first else { return nil }
        func value(_ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(w,name as CFString,&value) == .success ? value : nil
        }
        guard value(kAXRoleAttribute) as? String == kAXWindowRole else { return nil }
        if !forCard {
            guard value(kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
                  value("AXFullScreen") as? Bool == false, value(kAXModalAttribute) as? Bool == false else { return nil }
        }
        return w
    }
    init?(_ key: DesktopWindowKey, forCard: Bool = false) {
        guard let w = Self.exact(key, forCard: forCard) else { return nil }
        self.forCard = forCard
        self.key = key; element = w
    }
    func matches(_ now: DesktopWindowKey) -> Bool {
        now == key && Self.exact(now, forCard: forCard).map { CFEqual(element,$0) } == true
    }

    /// Only a fresh appearance can bridge a gap in the roster. The caller checks
    /// current sharing and process ownership independently on every image lookup.
    func matches(_ key: DesktopWindowKey, appearance: UUID, ownerUnchanged: () -> Bool) -> Bool {
        guard self.key == key else { return false }
        if verifiedAppearance == appearance { return true }
        guard ownerUnchanged(), matches(key) else { return false }
        verifiedAppearance = appearance
        return true
    }
}

/// Metadata for one pre-departure layout. Pixels live only in the shared, bounded gallery.
struct StageGroupDeparture: Equatable {
    struct Member: Identifiable, Equatable {
        let id: UUID, before: StageWindowState, appearance: UUID, layout: SurfaceRect, rank: Int
        var key: DesktopWindowKey { .init(pid: before.window.pid, birth: before.window.birth, number: before.window.number) }
    }
    let id, group, generation, session: UUID
    let scope: StageGroupScope, nativeID: UInt64, topology: String, area: SurfaceRect
    let members: [Member]
    func sameLayout(as other: Self) -> Bool {
        group == other.group && generation == other.generation && session == other.session && scope == other.scope &&
            nativeID == other.nativeID && topology == other.topology && area == other.area && members == other.members
    }
    struct Stamp: Equatable {
        let departure, group, generation, member, originalLifetime: UUID
    }
    func stamp(for member: Member) -> Stamp {
        .init(departure:id,group:group,generation:generation,member:member.id,originalLifetime:member.before.lifetime)
    }

    struct Selection: Equatable {
        let departure: UUID, member: Stamp?
    }
    func selection(at point: CGPoint, in size: CGSize, hasImage: (UUID) -> Bool) -> Selection? {
        guard CGRect(origin: .zero, size: size).contains(point) else { return nil }
        let location = CGPoint(x: point.x / size.width, y: point.y / size.height)
        for member in members.reversed() {
            let r = member.layout
            if CGRect(x: r.x, y: r.y, width: r.width, height: r.height).contains(location) {
                return hasImage(member.id) ? Selection(departure: id, member: stamp(for: member)) : nil
            }
        }
        return Selection(departure: id, member: nil)
    }

    func parkedMember(_ stamp: Stamp, in sample: StageWindowSample) -> (Member, StageWindowState)? {
        guard sample.scope == scope, sample.generation == generation, sample.nativeID == nativeID,
              let member = members.first(where: { $0.id == stamp.member }), self.stamp(for: member) == stamp,
              let state = sample.windows[member.before.window], state.window == member.before.window,
              state.lifetime == member.before.lifetime else { return nil }
        switch state.visibility {
        case .parked:
            guard state.hiddenSpaceID == nil else { return nil }
        case .stageSpace:
            guard let hidden = state.hiddenSpaceID, hidden > 0, hidden != nativeID else { return nil }
        default: return nil
        }
        return (member, state)
    }

    func matches(_ snapshot: DesktopSnapshot) -> Bool {
        let home = snapshot.scopes.filter { UUID(uuidString: $0.displayID) == scope.display }.flatMap(\.records).filter(\.isCurrent)
        return snapshot.sessionID == session && snapshot.topologyFingerprint == topology && snapshot.native?.stageManagerEnabled == false &&
            snapshot.topologyConsistent && home.count == 1 && home[0].fullscreenUUID == nil &&
            home[0].ordinaryUUID == scope.nativeSpace && UInt64(home[0].id) == nativeID
    }

    /// An observed sidebar picture must still belong to the same ordinary native desktop.
    func containsOriginal(_ member: Member, in snapshot: DesktopSnapshot, appearance: UUID?) -> Bool {
        guard matches(snapshot), snapshot.native?.catalogComplete == true,
              appearance == nil || appearance == member.appearance else { return false }
        let rows = snapshot.windows.filter { $0.metadata?.number == member.key.number }
        guard rows.count == 1, let row = rows.first else { return false }
        return DesktopWindowKey(row) == member.key && row.metadata?.fullScreen != true &&
            UUID(uuidString: row.displayID) == scope.display && row.membership == .known(recordIDs: [String(nativeID)])
    }

    static func observed(_ group: StageGroupDirectory.Group, scope: StageGroupScope, area: SurfaceRect,
                         opening: DesktopSnapshot, closing: DesktopSnapshot, earlierLifetimes: [DesktopWindowKey:UUID], lifetimes: [DesktopWindowKey:UUID],
                         earlierAppearances: [DesktopWindowKey:UUID], appearances: [DesktopWindowKey:UUID]) -> Self? {
        let home = closing.scopes.filter { UUID(uuidString:$0.displayID) == scope.display }.flatMap(\.records).filter(\.isCurrent)
        guard home.count == 1, home[0].ordinaryUUID == scope.nativeSpace, let native = UInt64(home[0].id),
              closing.native?.catalogComplete == true, opening.native?.catalogComplete == true else { return nil }
        var bindings = [NativeSpaceWindow:UUID]()
        func sample(_ inventory: DesktopSnapshot) -> StageWindowSample? {
            var found = [NativeSpaceWindow:StageWindowState]()
            for m in group.members {
                let id = m.windowHint, key = DesktopWindowKey(pid:id.pid,birth:id.birth,number:id.number)
                guard let life = lifetimes[key], life == earlierLifetimes[key],
                      let appeared = appearances[key], appeared == earlierAppearances[key],
                      let row = inventory.windows.first(where:{ DesktopWindowKey($0) == key }),
                      let target = DesktopWindowTarget.preview(row,in:inventory), target.publiclyVisible,
                      row.metadata?.overviewOrdinaryRole == true, row.metadata?.hasCatalogGeometry == true,
                      row.metadata?.catalogLogicalFrame.map({ $0 == target.frame }) != false else { return nil }
                bindings[id] = life
                found[id] = .init(window:id,lifetime:life,frame:target.frame,visibility:.visible)
            }
            return .init(scope:scope,generation:inventory.sessionID,sequence:inventory.revision,workArea:area,
                         windows:found,focus:nil,nativeID:native)
        }
        guard let a = sample(opening), let b = sample(closing) else { return nil }
        return read(group:group,first:a,second:b,opening:opening,closing:closing,appearances:appearances,authorized:bindings)
    }

    static func read(group: StageGroupDirectory.Group, first: StageWindowSample, second: StageWindowSample,
                     opening: DesktopSnapshot, closing: DesktopSnapshot, appearances: [DesktopWindowKey: UUID],
                     authorized: [NativeSpaceWindow: UUID]) -> Self? {
        guard !group.members.isEmpty, group.nativeSpace == second.scope.nativeSpace, group.needsReorganization != true,
              first.scope == second.scope, first.generation == second.generation, first.sequence < second.sequence,
              let native = second.nativeID, native > 0, first.nativeID == native, first.workArea == second.workArea,
              opening.sessionID == closing.sessionID, opening.revision < closing.revision,
              opening.topologyFingerprint == closing.topologyFingerprint else { return nil }
        func rank(_ key: DesktopWindowKey, in inventory: DesktopSnapshot) -> Int? {
            let rows = inventory.windows.filter { $0.metadata?.number == key.number }
            guard rows.count == 1, let row = rows.first, UUID(uuidString: row.displayID) == second.scope.display,
                  DesktopWindowKey(row) == key, row.membership == .known(recordIDs:[String(native)]),
                  row.metadata?.isOnscreen == true, let z = row.metadata?.frontToBack, z >= 0 else { return nil }
            return z
        }
        var ordered = [Member]()
        for m in group.members {
            let id = m.windowHint, key = DesktopWindowKey(pid:id.pid,birth:id.birth,number:id.number)
            guard let state = second.windows[id], state.window == id, first.windows[id] == state,
                  state.hiddenSpaceID == nil, authorized[id] == state.lifetime else { return nil }
            if state.visibility == .minimized {
                for inventory in [opening, closing] {
                    let rows = inventory.windows.filter { $0.metadata?.number == key.number }
                    guard rows.count == 1, let row = rows.first, DesktopWindowKey(row) == key,
                          row.metadata?.minimized == true, row.metadata?.isOnscreen == false,
                          UUID(uuidString: row.displayID) == second.scope.display,
                          row.membership == .known(recordIDs:[String(native)]) else { return nil }
                }
                continue
            }
            guard state.visibility == .visible,
                  let appearance = appearances[key], let layout = StageGroupWindow.relativeFrame(state.frame, in: second.workArea),
                  let z = rank(key, in: closing), z == rank(key, in: opening) else { return nil }
            ordered.append(.init(id:m.id,before:state,appearance:appearance,layout:layout,rank:z))
        }
        guard !ordered.isEmpty, Set(ordered.map(\.rank)).count == ordered.count else { return nil }
        let result = Self(id:UUID(),group:group.id,generation:second.generation,session:closing.sessionID,
            scope:second.scope,nativeID:native,topology:closing.topologyFingerprint,area:second.workArea,
            members:ordered.sorted { $0.rank > $1.rank })
        return result.matches(opening) && result.matches(closing) ? result : nil
    }
}

struct ObservedPictureGroups {
    let scope: StageGroupScope, area: SurfaceRect, groups: [StageGroupDirectory.Group]
    let visible: Set<UUID>, lifetimes: [DesktopWindowKey:UUID]
}

/// Front members draw last. A missing picture keeps its own opaque outline over windows behind it.
struct StageGroupHistoryPicture: View {
    let departure: StageGroupDeparture
    let images: [UUID: CGImage]
    var select: ((StageGroupDeparture.Stamp?) -> Void)? = nil
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(Array(departure.members.enumerated()), id: \.element.id) { index, member in
                    let r = member.layout, w = geometry.size.width * r.width, h = geometry.size.height * r.height
                    let tile = ZStack {
                        RoundedRectangle(cornerRadius: 2).fill(DesktopWindowCard.windowBacking(for: scheme))
                        if let image = images[member.id] {
                            Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        }
                    }
                    .frame(width:w,height:h).clipShape(RoundedRectangle(cornerRadius:2))
                    .overlay { RoundedRectangle(cornerRadius:2).strokeBorder(.primary.opacity(0.45),lineWidth:0.8) }
                    .contentShape(Rectangle())
                    Group {
                        if let select, images[member.id] != nil {
                            Button { select(departure.stamp(for: member)) } label: { tile }
                                .buttonStyle(.plain)
                                .accessibilityLabel("恢复组合并聚焦第 " + String(index + 1) + " 扇窗口")
                                .accessibilityIdentifier("held-window:" + member.id.uuidString)
                        } else {
                            tile.accessibilityHidden(true)
                        }
                    }.offset(x:geometry.size.width*r.x,y:geometry.size.height*r.y)
                }
            }.frame(width:geometry.size.width,height:geometry.size.height,alignment:.topLeading)
            .overlay {
                if let select {
                    DesktopMapWindowSelection(target: { point in
                        departure.selection(at: point, in: geometry.size) { images[$0] != nil }
                    }, select: { select($0.member) }).accessibilityHidden(true)
                }
            }
        }
        .aspectRatio(departure.area.width/departure.area.height,contentMode:.fit).clipped()
        .background(.primary.opacity(0.09), in:RoundedRectangle(cornerRadius:7))
        .overlay { RoundedRectangle(cornerRadius:7).strokeBorder(.primary.opacity(0.4)).allowsHitTesting(false) }
    }
}
