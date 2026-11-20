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
                frontToBack:index,minimized:nil,fullScreen:nil,axFrame:ax,isOnscreen:true,onActiveDesktop:active,
                hasCatalogGeometry: true))
    }
    func sample(_ windows: [WindowObservation], revision: UInt64 = 1, scope: String = "A") -> DesktopSnapshot {
        let rect = SurfaceRect(width:900,height:650)
        return .observed(.init(session:session,revision:revision,parentPID:1,fixtureWindows:nil,anchors:[],experimentalSpaces:false),
            from:time,to:time,build:"fixture",topology:"topology",consistent:true,separateSpaces:true,
            displays:[.init(id:"display",frame:rect,rotationDegrees:0,backingScale:2,usable:rect)],
            scopes:[.init(id:"scope",displayID:"display",records:[.init(id:scope,isCurrent:true)])],windows:windows,
            evidence:.init(population:.workWindows,accessibility:.denied,spaces:.observed,rows:[],windowLimitReached:false,beganUptime:99,endedUptime:100))
    }
    @Test func protectedPixelsDoNotPreventMetadataOnlySelection() {
        let selection = DesktopWindowTarget.SurfacePurpose.windowSelection
        let picture = DesktopWindowTarget.SurfacePurpose.picture
        #expect(selection.accepts(drawn: true, allowsContent: false))
        #expect(!picture.accepts(drawn: true, allowsContent: false))
        #expect(!selection.accepts(drawn: false, allowsContent: false))
        #expect(picture.accepts(drawn: true, allowsContent: true))
    }

    @Test func vanishedAndRecreatedWindowCannotReuseAnIdenticalCachedPicture() throws {
        let snapshot = sample([window()])
        let target = try #require(DesktopWindowTarget(snapshot.windows[0], in: snapshot))
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let original = UUID()
        let still = DesktopWindowGallery.Still(target: target, lifetime: original,
            capture: .init(image: image, logicalSize: CGSize(width: 320, height: 240)), time: 100)
        #expect(still.matches(target, lifetime: original, now: 101))
        #expect(!still.matches(target, lifetime: nil, now: 101))
        #expect(!still.matches(target, lifetime: UUID(), now: 101))
        #expect(!still.matches(target, lifetime: original, now: 112))
    }

    @Test func historicalStagePictureRequiresTheSameDocumentOnTheSameDeskAndExpires() throws {
        let desk = UUID(), lifetime = UUID()
        let logical = SurfaceRect(width: 520, height: 175)
        let strip = SurfaceRect(width: 199, height: 129)
        func target(_ presentation: SurfaceRect, logical logicalFrame: SurfaceRect?, deskID: UUID,
                    stage: Bool? = true, pid: Int32 = 41, space: String = "97") throws -> DesktopWindowTarget {
            var snapshot = catalog([(22, pid, true, "97")])
            snapshot.scopes = [.init(id: "scope", displayID: "display", records: [.init(id: space, isCurrent: true, ordinaryUUID: deskID)])]
            snapshot.native = .init(population: .workWindows, accessibility: .available, spaces: .observed, rows: [],
                                    windowLimitReached: false, beganUptime: 99, endedUptime: 100, stageManagerEnabled: stage)
            var w = WindowObservation(id: "one", displayID: "display", bounds: presentation,
                                      membership: .known(recordIDs: [space]), confidence: .unknown)
            w.metadata = .init(number: 22, pid: pid, launchMicroseconds: 100, element: nil, globalFrame: presentation,
                               frontToBack: 0, minimized: false, fullScreen: false, isOnscreen: true, onActiveDesktop: true,
                               overviewSpaceID: space, catalogLogicalFrame: logicalFrame)
            return try #require(DesktopWindowTarget(w, in: snapshot))
        }
        let original = try target(logical, logical: logical, deskID: desk)
        let staged = try target(strip, logical: logical, deskID: desk)
        let ctx = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let capture = DesktopWindowGallery.Capture(image: try #require(ctx.makeImage()), logicalSize: CGSize(width: 520, height: 175))
        var still = DesktopWindowGallery.Still(target: original, lifetime: lifetime, capture: capture, time: 100)
        #expect(still.matches(original, lifetime: lifetime, now: 101))
        #expect(!still.matches(staged, lifetime: lifetime, now: 101))
        #expect(still.canShowPrevious(staged, lifetime: lifetime, now: 155))
        #expect(!still.canShowPrevious(staged, lifetime: lifetime, now: 160))
        #expect(!still.canShowPrevious(staged, lifetime: UUID(), now: 101))
        #expect(!still.canShowPrevious(staged, lifetime: nil, now: 101))
        let transitioning = try target(strip, logical: nil, deskID: desk)
        #expect(still.canRetainPrevious(transitioning, lifetime: lifetime, now: 102))
        #expect(!still.canShowPrevious(transitioning, lifetime: lifetime, now: 102))
        #expect(!still.canRetainPrevious(transitioning, lifetime: lifetime, now: 103))
        #expect(!original.samePicture(as: try target(logical, logical: logical, deskID: UUID())))

        for mismatch in [try target(strip, logical: nil, deskID: desk),
                         try target(strip, logical: .init(width: 510, height: 175), deskID: desk),
                         try target(strip, logical: logical, deskID: UUID()),
                         try target(strip, logical: logical, deskID: desk, stage: nil),
                         try target(strip, logical: logical, deskID: desk, pid: 72),
                         try target(strip, logical: logical, deskID: desk, space: "98")] {
            #expect(!still.canShowPrevious(mismatch, lifetime: lifetime, now: 101))
        }
        // Reappearing at its original geometry alone does not refresh the image.
        still.use = .previous
        #expect(still.canShowPrevious(original, lifetime: lifetime, now: 105))
        #expect(!still.matches(original, lifetime: lifetime, now: 105))
        still.use = .mapOnly
        #expect(!still.canShowPrevious(staged, lifetime: lifetime, now: 105))
        let fresh = DesktopWindowGallery.Still(target: original, lifetime: lifetime, capture: capture, time: 106)
        #expect(fresh.matches(original, lifetime: lifetime, now: 106))
        #expect(!fresh.canShowPrevious(original, lifetime: lifetime, now: 106))
    }

    @Test func denialIsCoalescedButNeverDelaysRevocationOfAnExistingGrant() {
        var time: TimeInterval = 100, reads = 0, grant = false
        let access = WindowPermissionProbe(read: { reads += 1; return grant }, uptime: { time })
        for _ in 0..<75 { #expect(!access.allowed()) }
        #expect(reads == 1)
        grant = true
        time += 2
        #expect(access.allowed())
        grant = false
        #expect(!access.allowed())
        grant = true
        access.invalidate()
        #expect(access.allowed())
        #expect(reads == 4)
    }

    @Test func independentCardsFitTheirVerifiedWindowWithinTheSameBox() throws {
        let wide = window(frame: .init(x: -120, width: 1000, height: 200))
        let tall = window(number: 23, frame: .init(width: 200, height: 800))
        let small = window(number: 24, frame: .init(width: 100, height: 50))
        var other = window(number: 25, frame: .init(width: 2800, height: 900))
        other = .init(id: "other", displayID: "second", bounds: other.bounds, membership: .unknown,
                      confidence: .unknown, metadata: other.metadata)
        let windows = [wide, tall, small, other]
        let layout = DesktopWindowThumbnailLayout(display: sample(windows).displays.first)
        #expect(layout.fittedSize(for: wide, width: 200, heightLimit: 100) == CGSize(width: 200, height: 40))
        #expect(layout.fittedSize(for: tall, width: 200, heightLimit: 100) == CGSize(width: 25, height: 100))
        #expect(layout.fittedSize(for: small, width: 200, heightLimit: 100) == CGSize(width: 200, height: 100))
        #expect(layout.fittedSize(for: other, width: 200, heightLimit: 100) == nil)
        let captured = DesktopWindowThumbnailLayout(display: sample([small]).displays.first,
            capturedSizes: [24: CGSize(width: 600, height: 500)])
        #expect(captured.fittedSize(for: small, width: 180, heightLimit: 90) == CGSize(width: 108, height: 90))
    }

    @Test func stagePresentationDoesNotSupplyDimensionsOrRetainPixelsAfterResize() throws {
        let stage = window(frame: .init(x: -64, y: 602, width: 49, height: 76), ax: .init(x: -681, y: 64, width: 562, height: 422))
        let layout = DesktopWindowThumbnailLayout(display: sample([stage]).displays.first)
        #expect(layout.fittedSize(for: stage, width: 200, heightLimit: 100) == nil)
        let snapshot = catalog([(22, 41, true, "97")])
        let target = try #require(DesktopWindowTarget(snapshot.windows[0], in: snapshot))
        func sameSpaceTarget(_ frame: SurfaceRect) throws -> DesktopWindowTarget {
            let before = snapshot.windows[0]
            var member = WindowObservation(id: before.id, displayID: before.displayID, bounds: frame,
                                           membership: before.membership, confidence: before.confidence)
            member.metadata = .init(number: 22, pid: 41, launchMicroseconds: 100, element: nil, globalFrame: frame,
                                    frontToBack: 0, minimized: false, fullScreen: false, isOnscreen: true,
                                    onActiveDesktop: true, overviewSpaceID: "97", hasCatalogGeometry: true)
            return try #require(DesktopWindowTarget(member, in: snapshot))
        }
        let moved = try sameSpaceTarget(.init(x: 41, y: 90, width: frame.width, height: frame.height))
        let resized = try sameSpaceTarget(.init(x: 41, y: 90, width: frame.width / 2, height: frame.height))
        #expect(target.samePicture(as: moved))
        #expect(!target.samePicture(as: resized))
    }

    @Test func absentAXKeepsPubliclyDrawnSiblingsAndRejectsMembershipOnlyTargets() {
        let s = catalog([(1, 51, true, "97"), (2, 51, true, "97"), (3, 51, false, "97")],
                        accessibility: .denied)
        #expect(s.currentDesktopWindows(on: "display", now: time, uptime: 101).compactMap { $0.metadata?.number } == [1, 2])
        #expect(s.windows.compactMap { DesktopWindowTarget($0, in: s)?.key.number } == [1, 2])
    }

    @Test func membershipAloneCannotTurnTheStageStripIntoTheWindow() throws {
        func staged(logical: SurfaceRect?) -> WindowObservation {
            let strip = SurfaceRect(x: 1300, y: 740, width: 152, height: 141)
            return .init(id: "wide", displayID: "display", bounds: strip, membership: .known(recordIDs: ["A"]),
                         confidence: .unknown, metadata: .init(number: 22, pid: 41, launchMicroseconds: 100,
                            element: nil, globalFrame: strip, frontToBack: 0, minimized: nil, fullScreen: nil,
                            isOnscreen: true, onActiveDesktop: true, overviewSpaceID: "A", catalogLogicalFrame: logical))
        }
        let unknown = staged(logical: nil)
        let wide = staged(logical: .init(width: 540, height: 213))
        let display = sample([wide]).displays.first
        #expect(DesktopWindowThumbnailLayout(display: display).fittedSize(for: unknown, width: 180, heightLimit: 90) == nil)
        let size = try #require(DesktopWindowThumbnailLayout(display: display).fittedSize(for: wide, width: 180, heightLimit: 90))
        #expect(abs(size.width - 180) < 0.001 && abs(size.height - 71) < 0.001)
        let withStageImage = DesktopWindowThumbnailLayout(display: display,
            capturedSizes: [22: CGSize(width: 152, height: 141)])
        #expect(withStageImage.fittedSize(for: wide, width: 180, heightLimit: 90) == size)
        var s = sample([wide])
        s.scopes = [.init(id: "scope", displayID: "display", records: [.init(id: "A", isCurrent: true, ordinaryUUID: UUID())])]
        let target = try #require(DesktopWindowTarget(wide, in: s))
        #expect(target.acceptsContentSize(CGSize(width: 540, height: 213)))
        #expect(!target.acceptsContentSize(CGSize(width: 152, height: 141)))
        #expect(!target.acceptsContentSize(CGSize(width: 200, height: 400)))
    }

    @Test func resizingAWindowInvalidatesItsPictureEvenWhenStageStripIsUnchanged() throws {
        let snapshot = catalog([(22, 41, true, "97")])
        func target(logicalWidth: Double) throws -> DesktopWindowTarget {
            var member = snapshot.windows[0]
            let strip = SurfaceRect(x: 1300, y: 740, width: 152, height: 141)
            member.metadata = .init(number: 22, pid: 41, launchMicroseconds: 100, element: nil, globalFrame: strip,
                frontToBack: 0, minimized: false, fullScreen: false, isOnscreen: true, onActiveDesktop: true,
                overviewSpaceID: "97", hasCatalogGeometry: false, catalogLogicalFrame: .init(width: logicalWidth, height: 213))
            return try #require(DesktopWindowTarget(member, in: snapshot))
        }
        let original = try target(logicalWidth: 540)
        #expect(try original.samePicture(as: target(logicalWidth: 540)))
        #expect(try !original.samePicture(as: target(logicalWidth: 740)))
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
        q.choose(a, input: [1]) { _ in calls.append(a.number); await withCheckedContinuation { resume = $0 } } failed: { _ in Issue.record("first") }
        while resume == nil { await Task.yield() }
        for key in [a,b,c,c] {
            q.choose(key, input: [1]) { _ in calls.append(key.number) } failed: { _ in Issue.record("unexpected refusal") }
        }
        resume?.resume()
        for _ in 0..<100 where calls.count < 2 { await Task.yield() }
        #expect(calls == [1,3])
    }
    @Test func refusalDropsQueuedWindowInsteadOfFocusingASecondTarget() async {
        let q = WindowChoiceQueue(), a = DesktopWindowKey(pid:41,birth:100,number:1), b = DesktopWindowKey(pid:41,birth:100,number:2)
        var refused = false, second = false
        q.choose(a, input: [1]) { _ in throw OrdinaryWindowFailure("stale") } failed: { _ in refused = true }
        q.choose(b, input: [1]) { _ in second = true } failed: { _ in Issue.record("second ran") }
        for _ in 0..<100 where !refused { await Task.yield() }
        #expect(refused && !second)
    }

    @Test func latestPressOnSameWindowReplacesAnInvalidatedFocusRequest() async {
        let a = DesktopWindowKey(pid: 41, birth: 100, number: 1)
        let b = DesktopWindowKey(pid: 41, birth: 100, number: 2)
        for revisitThroughSibling in [false, true] {
            let queue = WindowChoiceQueue()
            var release: CheckedContinuation<Void, Never>?
            var finished = false
            var writes: [Int] = []
            queue.choose(a, input: [1]) { current in
                await withCheckedContinuation { release = $0 }
                if current() { writes.append(1) }
            } failed: { _ in Issue.record("unexpected first refusal") }
            while release == nil { await Task.yield() }
            if revisitThroughSibling {
                queue.choose(b, input: [1]) { _ in writes.append(2) } failed: { _ in Issue.record("unexpected second refusal") }
            }
            // AXPress may deliver A, B, A without advancing the physical-input counter.
            // A second physical press on A advances it even when there is no sibling.
            queue.choose(a, input: [revisitThroughSibling ? 1 : 2]) { current in
                if current() { writes.append(3) }
                finished = true
            } failed: { _ in Issue.record("unexpected final refusal") }
            release?.resume()
            for _ in 0..<200 where !finished { await Task.yield() }
            #expect(finished && writes == [3])
        }
        #expect(DesktopWindowSelection.SelectionPath.accessibility.focusNotice == nil)
        #expect(DesktopWindowSelection.SelectionPath.soleWindowApplication.focusNotice?.contains("键盘焦点尚未确认") == true)
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

    private func catalog(_ numbers: [(UInt32, Int32, Bool, String?)], current: String = "97",
                         accessibility: AXReadStatus = .available) -> DesktopSnapshot {
        let w = numbers.enumerated().map { index, entry in
            let (n, pid, visible, proof) = entry
            return WindowObservation(id: "win-\(n)", displayID: "display", bounds: frame,
                membership: proof.map { .known(recordIDs: [$0]) } ?? .unknown, confidence: .unknown,
                metadata: .init(number: n, pid: pid, launchMicroseconds: 100, element: nil, globalFrame: frame,
                    frontToBack: index, minimized: accessibility == .available ? false : nil, fullScreen: nil, isOnscreen: visible,
                    onActiveDesktop: visible, overviewSpaceID: proof, overviewIsPresented: visible || proof != nil))
        }
        var sample = sample(w)
        sample.native = .init(population: .workWindows, accessibility: accessibility, spaces: .observed,
            rows: [], windowLimitReached: false, beganUptime: 99, endedUptime: 100)
        sample.scopes = [.init(id: "scope", displayID: "display", records: ["97", "98"].map {
            .init(id: $0, isCurrent: $0 == current, ordinaryUUID: UUID(uuidString: "00000000-0000-0000-0000-0000000000" + $0))
        })]
        return sample
    }

    @Test func coveredSiblingsAndClassifiedStageWindowsStayInTheSameDesk() throws {
        let s = catalog([(1, 51, true, "97"), (2, 51, false, "97"), (3, 52, false, "97"), (4, 52, false, nil)])
        let members = s.currentDesktopWindows(on: "display", now: time, uptime: 101)
        #expect(members.compactMap { $0.metadata?.number } == [1, 2, 3])
        #expect(members.compactMap { DesktopWindowTarget($0, in: s) }.count == 3)
        #expect(!members[1].canRequestCurrentDesktopFocus && !members[1].canWitnessCurrentSpace)
        #expect(ManagedWindowID(members[1]) == nil)
    }

    @Test func membershipAloneCannotPublishMinimizedHiddenOrOtherSpaceWindows() {
        var s = catalog([])
        let ids = ["97", "98", "internal"]
        s.scopes = [.init(id: "scope", displayID: "display", records: ids.map {
            .init(id: $0, isCurrent: $0 == "97", ordinaryUUID: $0 == "internal" ? nil : UUID())
        })]
        let time = s.native!.endedUptime
        s.native = .init(population: .workWindows, accessibility: .available, spaces: .observed,
                         rows: [], windowLimitReached: false, beganUptime: time - 1, endedUptime: time, catalogComplete: false)
        func member(_ n: UInt32, _ space: String?, active: Bool, presented: Bool?, minimized: Bool? = false, ordinary: Bool? = true) -> WindowObservation {
            .init(id: "w-\(n)", displayID: "display", bounds: frame, membership: space.map { .known(recordIDs: [$0]) } ?? .unknown,
                  confidence: .unknown, metadata: .init(number: n, pid: 51, launchMicroseconds: 100, element: nil,
                  globalFrame: frame, frontToBack: Int(n), minimized: minimized, fullScreen: false,
                  isOnscreen: active, onActiveDesktop: active, overviewSpaceID: space == "97" ? space : nil, overviewIsPresented: presented, overviewOrdinaryRole: ordinary))
        }
        s.windows = [member(1, "97", active: true, presented: true), member(2, "97", active: true, presented: true),
                     member(3, "97", active: false, presented: true, minimized: false), // independently ordered stage member
                     member(4, "97", active: false, presented: true, minimized: true),
                     member(5, "97", active: false, presented: nil), member(6, "97", active: true, presented: false),
                     member(7, "98", active: true, presented: true), member(8, "internal", active: true, presented: true),
                     member(9, nil, active: true, presented: true),
                     member(10, "97", active: true, presented: true, minimized: nil, ordinary: nil),
                     member(11, "97", active: true, presented: true, ordinary: false)]
        #expect(s.isStructurallyValid)
        #expect(s.currentDesktopWindows(on: "display", now: self.time, uptime: time).compactMap { $0.metadata?.number } == [1, 2, 3])
        #expect(s.windows.compactMap { DesktopWindowTarget($0, in: s)?.key.number } == [1, 2, 3])
        #expect(s.unconfirmedCurrentDesktopWindowCount(on: "display", now: self.time, uptime: time) == 1)
        let candidate = s.windows[9]
        #expect(DesktopWindowTarget.tilingCandidate(candidate, in: s) != nil)
        #expect(DesktopWindowTarget(candidate, in: s) == nil)
        s.native = .init(population: .workWindows, accessibility: .denied, spaces: .observed,
                         rows: [], windowLimitReached: false, beganUptime: time - 1, endedUptime: time, catalogComplete: false)
        #expect(s.currentDesktopWindows(on: "display", now: self.time, uptime: time).isEmpty)
        #expect(s.unconfirmedCurrentDesktopWindowCount(on: "display", now: self.time, uptime: time) == 3)
        #expect(s.unconfirmedCurrentDesktopWindowCount(on: "another-display", now: self.time, uptime: time) == 0)
        #expect(s.unconfirmedCurrentDesktopWindowCount(on: "display", now: self.time, uptime: time + 120) == 0)
    }

    @Test func visiblePicturesAreProcessedBeforeAnyOffstageMembershipRecheck() throws {
        let s = catalog([(1, 51, false, "97"), (2, 51, true, "97"), (3, 52, false, "97"),
                         (4, 52, true, "97"), (5, 52, true, "97"), (6, 52, true, "97"), (7, 52, true, "97")])
        let targets = try s.windows.map { try #require(DesktopWindowTarget($0, in: s)) }
        let offstage = Set(targets.filter { !$0.publiclyVisible }.map(\.key))
        let batches = DesktopWindowGallery.captureBatches(targets, membership: offstage)
        #expect(batches.map { $0.map { $0.key.number } } == [[2, 4, 5, 6], [7], [1, 3]])
        #expect(DesktopWindowGallery.captureBatches([], membership: offstage).isEmpty)
    }

    @Test func scopeChangeClosureAndStaleSamplesInvalidateBackgroundPixels() throws {
        let s = catalog([(8, 51, false, "97")])
        let target = try #require(DesktopWindowTarget(s.windows[0], in: s))
        #expect(target.present(in: catalog([(8, 51, true, "97")]), now: time, uptime: 101))
        #expect(!target.present(in: catalog([(8, 51, true, "98")], current: "98"), now: time, uptime: 101))
        #expect(!target.present(in: catalog([]), now: time, uptime: 101))
        #expect(!target.present(in: s, now: time, uptime: 120))
        #expect(!catalog([(8, 51, false, "98")]).isStructurallyValid)
    }

    @Test func aScopedBackgroundWindowStillRequiresTheExactSoleOwnerForPublicActivation() {
        let key = DesktopWindowKey(pid: 51, birth: 100, number: 8)
        let off: [String: Any] = [kCGWindowNumber as String: UInt32(8), kCGWindowOwnerPID as String: Int32(51), kCGWindowLayer as String: 0]
        #expect(!DesktopWindowSelection.soleWindow(key, in: [off]))
        #expect(DesktopWindowSelection.soleWindow(key, in: [off], requireVisible: false))
        var sibling = off; sibling[kCGWindowNumber as String] = UInt32(9)
        #expect(!DesktopWindowSelection.soleWindow(key, in: [off, sibling], requireVisible: false))
    }

    @Test func changingStagePresentationKeepsOnlyTheOriginalScopedFocusIntent() throws {
        let before = catalog([(8, 51, false, "97")])
        let selected = try #require(DesktopWindowTarget(before.windows[0], in: before))
        var after = catalog([(8, 51, true, "97")])
        let frame = SurfaceRect(x: 42, y: 60, width: 720, height: 480)
        after.windows = [.init(id: "win-8", displayID: "display", bounds: frame, membership: .known(recordIDs: ["97"]),
            confidence: .unknown, metadata: .init(number: 8, pid: 51, launchMicroseconds: 100, element: nil,
            globalFrame: frame, frontToBack: 0, minimized: false, fullScreen: false,
            isOnscreen: true, onActiveDesktop: true, overviewSpaceID: "97"))]
        #expect(!selected.present(in: after, now: time, uptime: 101))
        #expect(selected.remainsSelection(in: after, now: time, uptime: 101))
        #expect(!selected.remainsSelection(in: after, now: time, uptime: 120))
        for invalid in [catalog([(8, 52, true, "97")]), catalog([(8, 51, true, "98")], current: "98"),
                        catalog([(8, 51, true, nil)]), catalog([])] {
            #expect(!selected.remainsSelection(in: invalid, now: time, uptime: 101))
        }
    }

    @Test func shortcutConflictChecksOnlyEnabledMatchingSystemChord() {
        let entry: [String: Any] = ["kHISymbolicHotKeyEnabled": true, "kHISymbolicHotKeyCode": 126, "kHISymbolicHotKeyModifiers": 4096]
        #expect(DesktopOverviewShortcut.systemReserves(4096, in: [entry]))
        #expect(!DesktopOverviewShortcut.systemReserves(6144, in: [entry]))
        var disabled = entry
        disabled["kHISymbolicHotKeyEnabled"] = false
        #expect(!DesktopOverviewShortcut.systemReserves(4096, in: [disabled]))
        var other = entry
        other["kHISymbolicHotKeyCode"] = 125
        #expect(!DesktopOverviewShortcut.systemReserves(4096, in: [other]))
    }
}
