import CoreGraphics
import Foundation
import NearpaneCore
@testable import NearpaneUI
import Testing

@MainActor struct DesktopGalleryTargetTests {
    let session = UUID()
    let time = Date()
    let frame = SurfaceRect(x:12,y:20,width:320,height:240)
    func window(number: UInt32 = 22, pid: Int32 = 41, birth: UInt64 = 100, active: Bool = true,
                frame override: SurfaceRect? = nil, ax: SurfaceRect? = nil, index: Int = 0, id: String = "one") -> WindowObservation {
        let rect = override ?? frame
        return .init(id:id,displayID:"display",bounds:rect,membership:.unknown,confidence:.unknown,
            metadata:.init(number:number,pid:pid,launchMicroseconds:birth,element:nil,globalFrame:rect,
                frontToBack:index,minimized:nil,fullScreen:nil,axFrame:ax,isOnscreen:true,onActiveDesktop:active))
    }
    func sample(_ windows: [WindowObservation], revision: UInt64 = 1, scope: String = "A") -> DesktopSnapshot {
        let rect = SurfaceRect(width:900,height:650)
        return .observed(.init(session:session,revision:revision,parentPID:1,fixtureWindows:nil,anchors:[],experimentalSpaces:false),
            from:time,to:time,build:"fixture",topology:"topology",consistent:true,separateSpaces:true,
            displays:[.init(id:"display",frame:rect,rotationDegrees:0,backingScale:2,usable:rect)],
            scopes:[.init(id:"scope",displayID:"display",records:[.init(id:scope,isCurrent:true)])],windows:windows,
            evidence:.init(population:.workWindows,accessibility:.denied,spaces:.observed,rows:[],windowLimitReached:false,beganUptime:99,endedUptime:100))
    }
    @Test func sameAppSiblingsHaveIndependentTargetsWithoutAccessibility() throws {
        let a = window(), b = window(number:23,index:1,id:"two")
        let snapshot = sample([a,b])
        let x = try #require(DesktopWindowTarget(a,in:snapshot)), y = try #require(DesktopWindowTarget(b,in:snapshot))
        #expect(x.key != y.key)
        #expect(x.present(in:snapshot,now:time,uptime:100))
        #expect(y.present(in:snapshot,now:time,uptime:100))
    }
    @Test func harmlessRefreshAndStackChangeKeepTheClick() throws {
        let old = window(), new = window(index:1,id:"revision2/owner/window")
        let target = try #require(DesktopWindowTarget(old,in:sample([old])))
        #expect(target.present(in:sample([new],revision:2),now:time,uptime:101))
    }
    @Test func changedBirthOwnerSpaceFrameAndInactiveWindowsRevokeBothPicturesAndClicks() throws {
        let w = window(), original = sample([w])
        let target = try #require(DesktopWindowTarget(w,in:original))
        for sample in [sample([window(birth:101)]),sample([window(pid:50)]),sample([w],scope:"B"),sample([window(active:false)]),
                       sample([window(frame:.init(x:20,y:30,width:280,height:150))]),sample([])] {
            #expect(!target.present(in:sample,now:time,uptime:101))
        }
        #expect(!target.present(in:original,now:time.addingTimeInterval(14),uptime:114))
        var later = original
        later.sessionID = UUID()
        #expect(!target.present(in:later,now:time,uptime:100))
    }
    @Test func archivedStageGeometryAndDuplicateNumbersAreRejected() throws {
        let w = window(frame:.init(x:-64,y:602,width:49,height:76), ax:.init(x:-681,y:64,width:562,height:422))
        #expect(DesktopWindowTarget(w,in:sample([w])) == nil)
        let a = window(), b = window(pid:42,id:"other")
        let target = try #require(DesktopWindowTarget(a,in:sample([a])))
        #expect(!target.present(in:sample([a,b]),now:time,uptime:100))
    }
    @Test func activationWithoutAccessibilityRejectsEverySameAppSiblingIncludingOffscreen() {
        let key = DesktopWindowKey(pid:41,birth:100,number:22)
        func row(_ number: UInt32, pid: Int32 = 41, on: Bool = true) -> [String:Any] {
            [kCGWindowOwnerPID as String:pid,kCGWindowNumber as String:number,kCGWindowIsOnscreen as String:on,kCGWindowLayer as String:0]
        }
        #expect(DesktopWindowSelection.soleWindow(key,in:[row(22),row(23,pid:42)]))
        #expect(!DesktopWindowSelection.soleWindow(key,in:[row(22),row(23)]))
        #expect(!DesktopWindowSelection.soleWindow(key,in:[row(22),row(23,on:false)]))
        #expect(!DesktopWindowSelection.soleWindow(key,in:[row(22,on:false)]))
        #expect(!DesktopWindowSelection.soleWindow(key,in:[row(22,pid:42)]))
    }
    @Test func rapidExplicitChoicesAreSerializedAndDuplicateClicksDoNotReplay() async {
        let q = WindowChoiceQueue(), a = DesktopWindowKey(pid:41,birth:100,number:1)
        let b = DesktopWindowKey(pid:41,birth:100,number:2), c = DesktopWindowKey(pid:41,birth:100,number:3)
        var calls = [UInt32]()
        var resume: CheckedContinuation<Void,Never>?
        q.choose(a) { calls.append(a.number); await withCheckedContinuation { resume = $0 } } failed: { _ in Issue.record("first") }
        while resume == nil { await Task.yield() }
        for key in [a,b,c,c] {
            q.choose(key) { calls.append(key.number) } failed: { _ in Issue.record("unexpected refusal") }
        }
        resume?.resume()
        for _ in 0..<100 where calls.count < 2 { await Task.yield() }
        #expect(calls == [1,3])
    }
    @Test func refusalDropsQueuedWindowInsteadOfFocusingASecondTarget() async {
        let q = WindowChoiceQueue(), a = DesktopWindowKey(pid:41,birth:100,number:1), b = DesktopWindowKey(pid:41,birth:100,number:2)
        var refused = false, second = false
        q.choose(a) { throw OrdinaryWindowFailure("stale") } failed: { _ in refused = true }
        q.choose(b) { second = true } failed: { _ in Issue.record("second ran") }
        for _ in 0..<100 where !refused { await Task.yield() }
        #expect(refused && !second)
    }
    @Test func galleryPreferenceSurvivesSaveAndLegacyConfigurationsDecode() throws {
        var configuration = HostConfiguration()
        configuration.showsWindowThumbnails = false
        let data = try JSONEncoder().encode(configuration)
        #expect(try JSONDecoder().decode(HostConfiguration.self,from:data).showsWindowThumbnails == false)
        var old = try #require(JSONSerialization.jsonObject(with:data) as? [String:Any])
        old.removeValue(forKey:"showsWindowThumbnails")
        #expect(try JSONDecoder().decode(HostConfiguration.self,from:JSONSerialization.data(withJSONObject:old)).showsWindowThumbnails)
    }
}
