import AppKit
import SwiftUI
import Testing
@testable import NearpaneCore
@testable import NearpaneUI

@MainActor struct StageGroupHistoryPictureTests {
    let scope = StageGroupScope(display:UUID(),nativeSpace:UUID()), session = UUID(), generation = UUID()
    let area = SurfaceRect(width:200,height:100)
    let back = NativeSpaceWindow(pid:440,birth:1200,number:51), front = NativeSpaceWindow(pid:440,birth:1200,number:52)
    let backLife = UUID(), frontLife = UUID(), groupID = UUID(), backMember = UUID(), frontMember = UUID()
    var members: [StageWindowState] {
        [.init(window:back,lifetime:backLife,frame:.init(x:10,y:10,width:120,height:60),visibility:.visible),
         .init(window:front,lifetime:frontLife,frame:.init(x:70,y:20,width:100,height:60),visibility:.visible)]
    }
    func snapshot(_ rev: UInt64, scope replacement: StageGroupScope? = nil, ranks: [Int] = [1,0], session other: UUID? = nil,
                  fullscreen: Bool = false, stage: Bool = false, birth: UInt64? = nil,
                  minimized: NativeSpaceWindow? = nil) -> DesktopSnapshot {
        let scope = replacement ?? scope, uptime = ProcessInfo.processInfo.systemUptime
        let rows = zip(members,ranks).map { state,rank in
            WindowObservation(id:String(state.window.number),displayID:scope.display.uuidString,bounds:state.frame,
                membership:.known(recordIDs:["4"]),confidence:.unknown,metadata:.init(number:state.window.number,pid:state.window.pid,
                    launchMicroseconds:birth ?? state.window.birth,element:nil,globalFrame:state.frame,frontToBack:rank,minimized:state.window == minimized,
                    fullScreen:false,isOnscreen:state.window != minimized,onActiveDesktop:true,overviewSpaceID:"4",hasCatalogGeometry:true,
                    catalogLogicalFrame:state.frame,overviewIsPresented:true,overviewOrdinaryRole:true))
        }
        return .observed(.init(session:other ?? session,revision:rev,parentPID:1,fixtureWindows:nil,anchors:[],experimentalSpaces:false),
            from:.now,to:.now,build:"fixture",topology:"one-screen",consistent:true,separateSpaces:true,
            displays:[.init(id:scope.display.uuidString,frame:area,rotationDegrees:0,backingScale:1,usable:area)],
            scopes:[.init(id:"scope",displayID:scope.display.uuidString,records:[.init(id:"4",isCurrent:true,
                ordinaryUUID:fullscreen ? nil : scope.nativeSpace,fullscreenUUID:fullscreen ? scope.nativeSpace : nil)])],
            windows:rows,evidence:.init(population:.workWindows,accessibility:.partial,spaces:.observed,rows:[],windowLimitReached:false,
                beganUptime:uptime,endedUptime:uptime,stageManagerEnabled:stage,catalogComplete:true))
    }
    func departure(opening: DesktopSnapshot? = nil, closing: DesktopSnapshot? = nil, lifetime: UUID? = nil,
                   minimized: NativeSpaceWindow? = nil) -> StageGroupDeparture? {
        let roster = StageGroupDirectory.Group(id:groupID,members:[
            .init(id:backMember,windowHint:back),.init(id:frontMember,windowHint:front)],nativeSpace:scope.nativeSpace)
        let appearances = Dictionary(uniqueKeysWithValues:members.map {
            (DesktopWindowKey(pid:$0.window.pid,birth:$0.window.birth,number:$0.window.number),$0.lifetime)
        })
        var states = Dictionary(uniqueKeysWithValues:members.map { ($0.window,$0) })
        if let minimized { states[minimized]?.visibility = .minimized }
        func read(_ seq:UInt64) -> StageWindowSample {
            .init(scope:scope,generation:generation,sequence:seq,workArea:area,windows:states,focus:front,nativeID:4)
        }
        return StageGroupDeparture.read(group:roster,first:read(1),second:read(2),opening:opening ?? snapshot(1),
            closing:closing ?? snapshot(2),appearances:appearances,authorized:[back:backLife,front:lifetime ?? frontLife])
    }
    @Test func historicalWorksetContainsOnlyIndependentlyVisibleMembers() throws {
        let before = snapshot(1, minimized: front), after = snapshot(2, minimized: front)
        let picture = try #require(departure(opening: before, closing: after, minimized: front))
        #expect(picture.members.map(\.id) == [backMember])
        #expect(departure(opening: before, closing: snapshot(2), minimized: front) == nil)
    }
    func image(red: Bool, width: Int, height: Int) throws -> CGImage {
        let space = try #require(CGColorSpace(name:CGColorSpace.sRGB))
        let context = try #require(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,
            space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        let color = try #require(CGColor(colorSpace:space,components:red ? [1,0,0,1] : [0,0,1,1]))
        context.setFillColor(color)
        context.fill(CGRect(x:0,y:0,width:width,height:height))
        return try #require(context.makeImage())
    }
    typealias Cache = PreviewPixelCache<DesktopWindowGallery.StillSlot,DesktopWindowGallery.Still>
    func still(_ m: StageGroupDeparture.Member, in group: StageGroupDeparture) throws -> DesktopWindowGallery.Still {
        let inventory = snapshot(2), row = try #require(inventory.windows.first { $0.metadata?.number == m.key.number })
        let target = try #require(DesktopWindowTarget.preview(row, in:inventory))
        let frame = m.before.frame, pixels = try image(red:m.id == backMember,width:Int(frame.width),height:Int(frame.height))
        return .init(target:target,lifetime:m.appearance,capture:.init(image:pixels,logicalSize:.init(width:frame.width,height:frame.height)),
                     time:100,departure:group.stamp(for:m))
    }
    @Test func independentGeometryAndFrontOrderMustAgreeBeforeSaving() throws {
        let group = try #require(departure())
        #expect(group.members.map(\.id) == [backMember,frontMember] && group.members[0].layout.x == 0.05)
        #expect(departure(opening:snapshot(1,ranks:[0,1])) == nil)
        #expect(departure(opening:snapshot(1,ranks:[0,0]),closing:snapshot(2,ranks:[0,0])) == nil)
        #expect(departure(lifetime:UUID()) == nil && departure(closing:snapshot(2,session:UUID())) == nil)
    }

    @Test func historicalPixelsConsumeVerifiedHiddenStateAndRejectReturnOrChangedOwnership() throws {
        let group = try #require(departure()), member = try #require(group.members.first)
        var hidden = member.before
        hidden.visibility = .stageSpace; hidden.hiddenSpaceID = 99
        let claim = StageWindowEngineWitness.VisibilityClaim(backend: .spaces, frame: hidden.frame, member: 99)
        func permits(_ state: StageWindowState, claim replacement: StageWindowEngineWitness.VisibilityClaim? = nil,
                     epoch: UUID? = nil, home: UInt64 = 4, source: StageGroupScope? = nil) -> Bool {
            let read = StageWindowSample(scope: source ?? scope, generation: epoch ?? generation, sequence: 3,
                workArea: area, windows: [state.window: state], focus: nil, nativeID: home)
            return StageWindowEngineWitness.confirmsHistoricalState(member, of: group, in: read, claim: replacement ?? claim)
        }
        #expect(permits(hidden))
        // Repainting while a retained receiver is being read must use the
        // completed sample. New visible/minimized states cannot keep old hides.
        #expect(!permits(member.before))
        var minimized = hidden; minimized.visibility = .minimized; minimized.hiddenSpaceID = nil
        #expect(!permits(minimized))
        var otherHide = hidden; otherHide.hiddenSpaceID = 100
        #expect(!permits(otherHide))
        var changedFrame = hidden; changedFrame.frame.x += 10
        #expect(!permits(changedFrame))
        let replacement = StageWindowState(window: hidden.window, lifetime: UUID(), frame: hidden.frame,
            visibility: .stageSpace, hiddenSpaceID: 99)
        #expect(!permits(replacement))
        #expect(!permits(hidden, epoch: UUID()))
        #expect(!permits(hidden, home: 5))
        #expect(!permits(hidden, source: .init(display: UUID(), nativeSpace: scope.nativeSpace)))
        #expect(!permits(hidden, claim: .init(backend: .corner, frame: hidden.frame, member: 4)))
        var atHome = hidden; atHome.hiddenSpaceID = 4
        #expect(!permits(atHome, claim: .init(backend: .spaces, frame: hidden.frame, member: 4)))

        // Preserve the historical Corner evidence rule without promoting it to
        // the production route or confusing a parked sliver with a hidden Space.
        var parked = member.before; parked.visibility = .parked; parked.frame.x = -100
        #expect(permits(parked, claim: .init(backend: .corner, frame: parked.frame, member: 4)))
        #expect(!permits(parked, claim: .init(backend: .corner, frame: parked.frame, member: 5)))
    }

    @Test func selectedHistoricalWindowMustStillBeTheSameParkedIncarnationOnTheSameDesktop() throws {
        let group = try #require(departure())
        let rear = try #require(group.members.first), stamp = group.stamp(for: rear)
        var parked = rear.before
        parked.visibility = .parked
        parked.frame.x = -100
        func read(_ state: StageWindowState, native: UInt64 = 4, epoch: UUID? = nil) -> StageWindowSample {
            .init(scope: scope, generation: epoch ?? generation, sequence: 3, workArea: area,
                  windows: [state.window: state], focus: nil, nativeID: native)
        }
        let accepted = try #require(group.parkedMember(stamp, in: read(parked)))
        #expect(accepted.0.id == backMember && accepted.1 == parked)
        let sibling = try #require(group.members.last)
        let env = StageEngineEnvironment(osBuild: "26A428", engineRevision: String(repeating: "1",count: 40),
            hostCDHash: String(repeating: "2",count: 40), hardware: "fixture", topology: "fixture",
            windowClass: "ordinary-standard", sipEnabled: true)
        let owner = StageEngineOwner(qualification: .init(backend: .corner, environment: env, evidence: UUID(), checks: [:]),
            generation: group.generation)
        let card = StageWindowEngineHost.HeldGroup(id: group.group, member: rear.id, scope: group.scope, state: parked,
            owner: owner, count: 2, departure: group)
        #expect(card.memberIdentity(nil)?.window == rear.before.window)
        let exact = try #require(card.memberIdentity(group.stamp(for: sibling)))
        #expect(exact.member == sibling.id && exact.window == sibling.before.window && exact.lifetime == sibling.before.lifetime)
        let older = try #require(departure())
        #expect(card.memberIdentity(older.stamp(for: sibling)) == nil)
        #expect(group.parkedMember(group.stamp(for: sibling), in: read(parked)) == nil)
        #expect(group.parkedMember(stamp, in: read(rear.before)) == nil)
        #expect(group.parkedMember(stamp, in: read(parked, native: 5)) == nil)
        #expect(group.parkedMember(stamp, in: read(parked, epoch: UUID())) == nil)
        let reused = StageWindowState(window: parked.window, lifetime: UUID(), frame: parked.frame, visibility: .parked)
        #expect(group.parkedMember(stamp, in: read(reused)) == nil)
        #expect(try #require(departure()).parkedMember(stamp, in: read(parked)) == nil)
    }

    @Test func exactHistoricalSelectionAcceptsOnlyTheOriginalWindowInAnIndependentHiddenSpace() throws {
        let group = try #require(departure()), member = try #require(group.members.first)
        let stamp = group.stamp(for: member)
        var hidden = member.before
        hidden.visibility = .stageSpace
        hidden.hiddenSpaceID = 98
        func read(_ state: StageWindowState) -> StageWindowSample {
            .init(scope: scope, generation: generation, sequence: 3, workArea: area,
                  windows: [state.window: state], focus: nil, nativeID: 4)
        }
        let selected = try #require(group.parkedMember(stamp, in: read(hidden)))
        #expect(selected.0.id == member.id && selected.1 == hidden)
        let invalidSpaces: [UInt64?] = [nil, 0, 4]
        for space in invalidSpaces {
            var invalid = hidden
            invalid.hiddenSpaceID = space
            #expect(group.parkedMember(stamp, in: read(invalid)) == nil)
        }
        for visibility in [StageWindowState.Visibility.visible, .minimized, .parked] {
            var invalid = hidden
            invalid.visibility = visibility
            #expect(group.parkedMember(stamp, in: read(invalid)) == nil)
        }
        let reincarnated = StageWindowState(window: hidden.window, lifetime: UUID(), frame: hidden.frame,
                                           visibility: .stageSpace, hiddenSpaceID: 98)
        #expect(group.parkedMember(stamp, in: read(reincarnated)) == nil)
        #expect(try #require(departure()).parkedMember(stamp, in: read(hidden)) == nil)
    }

    @Test func historicalClicksUseWindowStackingAndNeverFallThroughAMissingFrontImage() throws {
        let group = try #require(departure())
        let backImage = try image(red: true, width: 120, height: 60)
        let frontImage = try image(red: false, width: 100, height: 60)
        var selected = [StageGroupDeparture.Stamp?]()
        func card(_ images: [UUID: CGImage], from picture: StageGroupDeparture) -> some View {
            StageGroupHistoryPicture(departure: picture, images: images, select: { selected.append($0) })
                .frame(width: 200, height: 100)
        }
        let complete = [backMember: backImage, frontMember: frontImage]
        let view = NSHostingView(rootView: card(complete, from: group))
        let panel = EdgePanel(contentRect: .init(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.contentView = view
        defer { panel.close() }
        func send(_ type: NSEvent.EventType, x: CGFloat) throws {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            let location = NSPoint(x: x, y: 50)
            let receiver = try #require(view.hitTest(location) as? DesktopMapWindowSelection<StageGroupDeparture.Selection>.MapView)
            let event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            switch type {
            case .leftMouseDown: receiver.mouseDown(with: event)
            case .leftMouseDragged: receiver.mouseDragged(with: event)
            case .leftMouseUp: receiver.mouseUp(with: event)
            default: Issue.record("Unexpected local test event")
            }
        }
        func click(_ x: CGFloat) throws {
            try send(.leftMouseDown, x: x)
            try send(.leftMouseUp, x: x)
        }
        try click(35)
        try click(100)
        try click(190)
        let rear = try #require(group.members.first), top = try #require(group.members.last)
        #expect(selected == [group.stamp(for: rear), group.stamp(for: top), nil])
        selected.removeAll()
        try send(.leftMouseDown, x: 100)
        view.rootView = card([backMember: backImage], from: group)
        try send(.leftMouseUp, x: 100)
        try click(100)
        try send(.leftMouseDown, x: 35)
        try send(.leftMouseDragged, x: 43)
        try send(.leftMouseUp, x: 35)
        try click(35)
        #expect(selected == [group.stamp(for: rear)])
        try send(.leftMouseDown, x: 35)
        view.rootView = card(complete, from: try #require(departure()))
        try send(.leftMouseUp, x: 35)
        #expect(selected == [group.stamp(for: rear)])
        #expect(!panel.isVisible && !panel.isKeyWindow)
    }

    @Test func alreadyDisplayedOrdinaryGroupCanKeepPixelsWithoutAnyWindowEngineOrNewCapture() throws {
        let opening = snapshot(1), closing = snapshot(2)
        let directory = StageGroupStore(profile:nil)
        let host = StageWindowEngineHost(profile:nil,store:directory)
        let windows = members.map { StageGroupWindow(display:scope.display,identity:$0.window,lifetime:$0.lifetime,
            layout:StageGroupWindow.relativeFrame($0.frame,in:area),nativeSpace:scope.nativeSpace) }
        #expect(!host.routesGroupChoice && !host.holdsDispatch)
        try host.observeDirectory(windows,in:directory)
        #expect(directory.projectedGroups(on:scope.display,among:windows).count == 2)
        try directory.join(windows[0],to:windows[1])
        let joined = directory.projectedGroups(on:scope.display,among:windows)
        try #require(joined.count == 1)
        let roster = try #require(joined.first)
        let lives = Dictionary(uniqueKeysWithValues:members.map { (DesktopWindowKey(pid:$0.window.pid,birth:$0.window.birth,
            number:$0.window.number),$0.lifetime) })
        func observe(earlier: [DesktopWindowKey: UUID], appeared: [DesktopWindowKey: UUID]) -> StageGroupDeparture? {
            StageGroupDeparture.observed(roster,scope:scope,area:area,opening:opening,closing:closing,
                earlierLifetimes:earlier,lifetimes:lives,earlierAppearances:appeared,appearances:lives)
        }
        let group = try #require(observe(earlier:lives,appeared:lives))
        let member = try #require(group.members.first), saved = try still(member,in:group), cache = Cache()
        let cost = try #require(PreviewPixelBudget.charge(saved.capture.image))
        func read(_ inventory:DesktopSnapshot, granted:Bool) -> CGImage? {
            DesktopWindowGallery.heldPixels(member,departure:group,snapshot:inventory,cache:cache,appearance:nil,now:104,observed:true) { _ in granted }
        }
        cache.store(saved,for:.current(member.key),cost:cost)
        #expect(read(closing,granted:true) == nil)
        cache.store(saved,for:.observed(member.key),cost:cost)
        #expect(read(snapshot(3),granted:true) === saved.capture.image && read(snapshot(3),granted:false) == nil)
        #expect(read(snapshot(3,scope:.init(display:scope.display,nativeSpace:UUID())),granted:true) == nil)
        #expect(observe(earlier:lives,appeared:[:]) == nil)
        var replacement = lives
        replacement[member.key] = UUID()
        #expect(observe(earlier:lives,appeared:replacement) == nil)
        #expect(observe(earlier:replacement,appeared:lives) == nil)
        #expect(group.containsOriginal(member,in:closing,appearance:member.appearance))
        #expect(!group.containsOriginal(member,in:closing,appearance:UUID()))
        #expect(!group.containsOriginal(member,in:snapshot(3,birth:member.key.birth+1),appearance:member.appearance))
        #expect(!group.containsOriginal(member,in:snapshot(3,fullscreen:true),appearance:member.appearance))
        #expect(!group.containsOriginal(member,in:snapshot(3,stage:true),appearance:member.appearance))
        #expect(!host.routesGroupChoice && !host.holdsDispatch)
    }
    @Test func firstCompositorFrameAfterDepartureBecomesHistoryWithoutAnEarlierDraw() throws {
        let group = try #require(departure()), member = try #require(group.members.first)
        var delivered = try still(member, in: group)
        delivered.departure = nil
        let pending = DesktopWindowGallery.PendingHeldPicture(departure: group, member: member, target: delivered.target,
            current: { true }, confirmsHidden: { true }, requested: 99)
        let stream = UUID(), cache = Cache()
        #expect(pending.canStart(at: 99) && !pending.canStart(at: 105))
        #expect(pending.bind(stream, started: 99) && !pending.bind(UUID(), started: 100))
        #expect(!pending.canStart(at: 100) && cache.count == 0)
        let saved = try #require(pending.accepts(delivered, stream: stream, now: 101))
        cache.store(saved, for: .held(member.key), cost: try #require(PreviewPixelBudget.charge(saved.capture.image)))
        var hidden = snapshot(3)
        hidden.windows.removeAll()
        let actual = DesktopWindowGallery.heldPixels(member, departure: group, snapshot: hidden, cache: cache,
            appearance: nil, now: 102) { _ in true }
        #expect(actual === delivered.capture.image)
        #expect(pending.accepts(delivered, stream: stream, now: 105) == nil)
        #expect(pending.bind(stream, started: 200) && pending.started == 99)
        // The hidden first-frame budget must not discard a new, independently
        // admitted current-surface frame while window dispatch is still running.
        let current = DesktopWindowGallery.Still(target: delivered.target, lifetime: member.appearance,
            capture: delivered.capture, time: 105)
        #expect(pending.accepts(current, stream: stream, now: 105, currentSurface: true)?.capture.image === delivered.capture.image)
    }

    @Test func pendingFirstFrameRejectsChangedLifetimeStreamAndRevokedOriginal() throws {
        let group = try #require(departure()), member = try #require(group.members.first), delivered = try still(member, in: group)
        var current = true
        let pending = DesktopWindowGallery.PendingHeldPicture(departure: group, member: member, target: delivered.target,
            current: { current }, confirmsHidden: { true }, requested: 99)
        let stream = UUID()
        #expect(pending.bind(stream, started: 99))
        let replaced = DesktopWindowGallery.Still(target: delivered.target, lifetime: UUID(), capture: delivered.capture, time: 100)
        #expect(pending.accepts(replaced, stream: stream, now: 101) == nil)
        #expect(!pending.matches(delivered.target, appearance: UUID()))
        #expect(pending.accepts(delivered, stream: UUID(), now: 101) == nil)
        current = false
        #expect(pending.accepts(delivered, stream: stream, now: 101) == nil)
    }

    @Test func heldPixelsOutliveTheCaptureButRejectReusedIdentityWrongSpaceAndLostPermission() throws {
        let group = try #require(departure()), m = try #require(group.members.first), saved = try still(m,in:group)
        let cache = Cache(maxCount:2,maxBytes:400_000)
        let cost = try #require(PreviewPixelBudget.charge(saved.capture.image))
        cache.store(saved,for:.held(m.key),cost:cost)
        func pixels(_ snapshot:DesktopSnapshot, at time:Double=101, appearance:UUID?=nil, grant:Bool=true) -> CGImage? {
            DesktopWindowGallery.heldPixels(m,departure:group,snapshot:snapshot,cache:cache,appearance:appearance,now:time) { _ in grant }
        }
        #expect(pixels(snapshot(3)) === saved.capture.image)
        #expect(pixels(snapshot(3),at:3700) === saved.capture.image && pixels(snapshot(3),at:99) == nil)
        #expect(pixels(snapshot(3),appearance:UUID()) == nil && pixels(snapshot(3),grant:false) == nil)
        #expect(pixels(snapshot(3,scope:.init(display:scope.display,nativeSpace:UUID()))) == nil)
        #expect(pixels(snapshot(3,scope:.init(display:UUID(),nativeSpace:scope.nativeSpace))) == nil)
        #expect(pixels(snapshot(3,session:UUID())) == nil)
        let successor = StageGroupDeparture.Member(id:m.id,before:.init(window:m.before.window,lifetime:UUID(),frame:m.before.frame,visibility:.visible),
            appearance:m.appearance,layout:m.layout,rank:m.rank)
        let reused = StageGroupDeparture(id:group.id,group:group.group,generation:group.generation,session:session,scope:scope,
            nativeID:4,topology:group.topology,area:area,members:[successor])
        #expect(!saved.matchesDeparture(successor,reused,now:101,appearance:nil))
        let replacement = try #require(departure())
        #expect(!saved.matchesDeparture(m,replacement,now:101,appearance:nil))
        cache.store(saved,for:.current(m.key),cost:cost)
        let f = try #require(group.members.last)
        cache.store(try still(f,in:group),for:.current(f.key),cost:cost)
        #expect(cache.count == 2 && cache.bytes == cost*2 && cache.peek(.current(m.key)) != nil && pixels(snapshot(3)) == nil)
    }

    @Test func coveredDisplayRetainsBothGroupMembersWhileOnlyTheirHomeDesktopCanDrawThem() throws {
        let group = try #require(departure())
        let cache = Cache()
        let gallery = DesktopWindowGallery(permitsWindow: { _ in true }, cache: cache, lifetime: { _ in nil })
        let home = snapshot(3), away = snapshot(4,scope:.init(display:scope.display,nativeSpace:UUID()))
        for member in group.members {
            let saved = try still(member,in:group)
            cache.store(saved,for:.observed(member.key),cost:try #require(PreviewPixelBudget.charge(saved.capture.image)))
        }
        func frames(_ inventory: DesktopSnapshot) -> [CGImage] {
            group.members.compactMap { member in
                DesktopWindowGallery.heldPixels(member,departure:group,snapshot:inventory,cache:cache,appearance:member.appearance,
                                                now:3700,observed:true) { _ in true }
            }
        }
        let original = group.members.compactMap { cache.peek(.observed($0.key))?.capture.image }
        gallery.clear(display:scope.display.uuidString,keepingCardFrames:true)
        #expect(frames(away).isEmpty)
        let returned = frames(home)
        #expect(returned.count == 2 && zip(original,returned).allSatisfy { $0 === $1 })
        gallery.clear(display:scope.display.uuidString)
        #expect(cache.count == 0 && frames(home).isEmpty)
    }

    @Test func productionGroupPictureRendersTheTwoStoredMembersInTheirActualOverlappingSlots() throws {
        let group = try #require(departure()), inventory = snapshot(3)
        let cache = Cache()
        for m in group.members {
            let saved = try still(m,in:group)
            cache.store(saved,for:.held(m.key),cost:try #require(PreviewPixelBudget.charge(saved.capture.image)))
        }
        func render(denying frontUnavailable:Bool) throws -> NSBitmapImageRep {
            var images = [UUID:CGImage]()
            for m in group.members {
                images[m.id] = DesktopWindowGallery.heldPixels(m,departure:group,snapshot:inventory,cache:cache,appearance:nil,now:101) {
                    _ in !frontUnavailable || m.id != frontMember
                }
            }
            let view = StageGroupHistoryPicture(departure:group,images:images).frame(width:200,height:100).environment(\.colorScheme,.light)
            let renderer = ImageRenderer(content:view); renderer.scale = 1
            let bitmap = NSBitmapImageRep(cgImage:try #require(renderer.cgImage))
            let data = try #require(bitmap.representation(using:.png,properties:[:]))
            if let output = ProcessInfo.processInfo.environment["NEARPANE_ROSTER_SAMPLE_DIR"] {
                let filename = frontUnavailable ? "historical-group-partial.png" : "historical-group-complete.png"
                try data.write(to:URL(fileURLWithPath:output).appendingPathComponent(filename),options:.withoutOverwriting)
            }
            return try #require(NSBitmapImageRep(data:data))
        }
        func channels(_ bitmap:NSBitmapImageRep, _ x:Int) throws -> [Int] {
            try #require(bitmap.samplesPerPixel == 4 && bitmap.bitsPerSample == 8 && bitmap.colorSpace == .sRGB)
            var rgba = [Int](repeating:0,count:4)
            bitmap.getPixel(&rgba,atX:x,y:47)
            return rgba
        }
        let complete = try render(denying:false), partial = try render(denying:true)
        #expect(complete.pixelsWide == 200 && complete.pixelsHigh == 100)
        #expect(try channels(complete,35) == [255,0,0,255])
        #expect(try channels(complete,100) == [0,0,255,255])
        #expect(try channels(complete,150) == [0,0,255,255])
        #expect(try channels(partial,35) == [255,0,0,255])
        let mask = try channels(partial,100)
        #expect(mask[0] == mask[1] && mask[1] == mask[2] && mask[3] == 255)
        #expect(try channels(partial,150) == mask)
    }
}
