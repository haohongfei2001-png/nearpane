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
    @Test func heldPixelsExpireAndRejectReusedIdentityWrongSpaceAndLostPermission() throws {
        let group = try #require(departure()), m = try #require(group.members.first), saved = try still(m,in:group)
        let cache = Cache(maxCount:2,maxBytes:400_000)
        let cost = try #require(PreviewPixelBudget.charge(saved.capture.image))
        cache.store(saved,for:.held(m.key),cost:cost)
        func pixels(_ snapshot:DesktopSnapshot, at time:Double=101, appearance:UUID?=nil, grant:Bool=true) -> CGImage? {
            DesktopWindowGallery.heldPixels(m,departure:group,snapshot:snapshot,cache:cache,appearance:appearance,now:time) { _ in grant }
        }
        #expect(pixels(snapshot(3)) === saved.capture.image)
        #expect(pixels(snapshot(3),at:160) == nil && pixels(snapshot(3),at:99) == nil)
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
