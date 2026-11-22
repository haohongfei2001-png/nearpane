import Foundation
import Testing
@testable import NearpaneHost

@MainActor struct StageInteractivePairTests {
    typealias JSON = [String: Any]
    @Test func stationaryButtonsAndSecureInputPreventEachSubsequentEffect() throws {
        let clear = StageInteractivePair.InputState(secure:false,hardwareButtons:0,sessionButtons:0)
        let blocked = [StageInteractivePair.InputState(secure:true,hardwareButtons:0,sessionButtons:0),
                       .init(secure:false,hardwareButtons:1 << 31,sessionButtons:0),
                       .init(secure:false,hardwareButtons:0,sessionButtons:1 << 27)]
        for stop in blocked {
            var effects = 0
            #expect(throws: StagePairRefusal.self) { try StageInteractivePair.whileInputClear({stop}) { effects += 1 } }
            #expect(effects == 0)
            try StageInteractivePair.whileInputClear({clear}) { effects += 1 }
            #expect(throws: StagePairRefusal.self) { try StageInteractivePair.whileInputClear({stop}) { effects += 1 } }
            #expect(effects == 1)
        }
    }

    @Test func predictsBothDecoratedFixtureFramesInWindowServerCoordinates() throws {
        let frames = try StageInteractiveFootprint.project(screen: CGRect(x:0,y:0,width:1200,height:900),
                                                          visible: CGRect(x:0,y:30,width:1200,height:845)) { content in
            // AppKit's style conversion is supplied by the real Host. Model a 26 pt title bar here.
            CGRect(x:content.minX,y:content.minY,width:content.width,height:content.height+26)
        }
        #expect(frames == [CGRect(x:20,y:59,width:264,height:206), CGRect(x:296,y:59,width:264,height:206)])
    }

    @Test func collisionChangedCensusOrUnknownOwnerCannotOpenEitherWindow() throws {
        typealias Footprint = StageInteractiveFootprint
        let a = CGRect(x:20,y:59,width:264,height:206), b = a.offsetBy(dx:276,dy:0)
        let foreground = Footprint.Window(pid:51,number:100,frame:CGRect(x:620,y:48,width:320,height:250))
        func scan(_ windows: [Footprint.Window]) throws -> Footprint {
            try Footprint(proposed:[a,b],windows:windows,foregroundPID:51,foregroundWindow:100,uptime:3)
        }
        let first = try scan([foreground])
        #expect(try scan([foreground]).assess(previous:first).reason == nil)
        for rect in [CGRect(x:30,y:60,width:45,height:4), b.insetBy(dx:48,dy:32)] {
            let intruder = Footprint.Window(pid:55,number:108,frame:rect)
            let check = try scan([foreground,intruder]).assess(previous:first)
            #expect(check.reason == "unregisteredOnscreenWindowIntersectsFixture")
            #expect(!String(describing:check.evidence).contains("number"))
        }
        let movedOutside = Footprint.Window(pid:51,number:100,frame:foreground.frame.offsetBy(dx:5,dy:0))
        #expect(try scan([movedOutside]).assess(previous:first).reason == "fixtureWindowCensusChanged")
        #expect(throws:StagePairRefusal.self) { try scan([]) }
        #expect(throws:StagePairRefusal.self) { try scan([foreground,foreground]) }
        #expect(throws:StagePairRefusal.self) { try scan([foreground,.init(pid:0,number:107,frame:b)]) }

        let left = Footprint.Window(pid:74,number:201,frame:a), right = Footprint.Window(pid:74,number:202,frame:b)
        let exact = [left,right], observed = try scan([left,foreground,right])
        #expect(observed.assess(previous:first).reason != nil)
        #expect(observed.assess(previous:first,registered:exact).reason == nil)
        for mismatched in [Footprint.Window(pid:99,number:201,frame:a), .init(pid:74,number:200,frame:a),
                           .init(pid:74,number:201,frame:a.offsetBy(dx:2,dy:0))] {
            #expect(try scan([mismatched,right,foreground]).assess(previous:first,registered:exact).reason != nil)
        }
        let under = Footprint.Window(pid:88,number:155,frame:a)
        #expect(try scan([left,right,under,foreground]).assess(previous:first,registered:exact).reason == "unregisteredOnscreenWindowIntersectsFixture")
    }

    @Test func bothOrdinaryScopesPermissionUnchangedHIDAndHeldForegroundAreRequired() {
        func sample(_ id: Int, post: Bool = true) -> JSON {
            let display: JSON = ["topologyConfirmed":true, "activeCGCount":UInt32(1)]
            let shot: JSON = ["session":["qualified":true,"securitySessionID":UInt32(53)] as JSON,"display":display]
            return ["permissions":["accessibility":true,"listenEvent":true,"postEvent":post],
                    "system":["build":"26A428","sip":["enabled":true]] as JSON,
                    "spaceScope":["scope":["status":"PASS","nativeID":id] as JSON,"samples":[shot,shot]] as JSON]
        }
        let old = sample(31), hid = [UInt32](repeating:4,count:14), held: JSON = ["sameOriginalAX":true]
        #expect(StageInteractivePair.accepts(old,old,focus:held,beganHID:hid,currentHID:hid))
        #expect(!StageInteractivePair.accepts(old,sample(32),focus:held,beganHID:hid,currentHID:hid))
        #expect(!StageInteractivePair.accepts(old,old,focus:["sameOriginalAX":false],beganHID:hid,currentHID:hid))
        #expect(!StageInteractivePair.accepts(old,old,focus:held,beganHID:hid,currentHID:hid + [0]))
        #expect(!StageInteractivePair.accepts(sample(31,post:false),sample(31,post:false),focus:held,beganHID:hid,currentHID:hid))
    }

    private func windows() -> [JSON] {
        ["target","sibling"].enumerated().map { i, role in
            ["role":role, "window":Int(100+i), "lifetime":UUID().uuidString,
             "frame":[10 + i*180,40,160,135], "sameOriginal":true,"visible":true,"onActiveSpace":true,
             "minimized":false,"key":false,"main":false,"firstResponderIsContent":true,"acceptsMouse":true,"alpha":1]
        }
    }

    @Test func missingSiblingAliasedLifetimeOpacityOrOverlappingFramesRefuse() throws {
        let original = windows()
        #expect(try StageInteractiveWindows.decoded(original).count == 2)
        let changed: [String:Any] = ["role":"target","window":100,"lifetime":try #require(original[0]["lifetime"]),
                                     "frame":[20,40,160,135],"alpha":0,"onActiveSpace":false,"sameOriginal":false,
                                     "minimized":true,"acceptsMouse":false]
        for (key,value) in changed {
            var rows = original; rows[1][key] = value
            #expect(throws:(any Error).self) { try StageInteractiveWindows.decoded(rows) }
        }
        #expect(throws:(any Error).self) { try StageInteractiveWindows.decoded([original[0]]) }
        let a = CGRect(x:2,y:3,width:200,height:300)
        #expect(!StageInteractiveWindows.equalFrame(a,a.offsetBy(dx:1,dy:0)))
    }

    @Test func authenticatedFixtureReportRequiresTaggedIntentAndExactUntouchedSibling() {
        let intent = UUID(), pid: Int32 = 74
        let empty: JSON = ["down":0,"drag":0,"up":0,"orderConflict":false]
        let seen: JSON = ["down":1,"drag":1,"up":1,"orderConflict":false]
        let target: JSON = ["role":"target","appQueue":seen,"contentView":seen]
        let sibling: JSON = ["role":"sibling","appQueue":empty,"contentView":empty]
        var row: JSON = ["intent":intent.uuidString,"sourcePID":pid,"kind":"mouse","receiver":"target","status":"PASS",
                         "reason":"matchingQueueAndContentDelivery","receivers":[target,sibling]]
        func pass(_ r: JSON) -> Bool { StageInteractivePair.deliveryConfirmed(r,intent:intent,kind:"mouse",receiver:"target",pid:pid) }
        #expect(pass(row))
        for rows in [[target,sibling,[:]], [target], [target,["role":"sibling","appQueue":empty,"contentView":seen]],
                     [["role":"target","appQueue":seen,"contentView":empty],sibling]] {
            var bad = row; bad["receivers"] = rows; #expect(!pass(bad))
        }
        for (key,value) in ["sourcePID":75, "intent":UUID().uuidString, "status":"UNKNOWN",
                            "receiver":"sibling","kind":"key"] as JSON {
            var bad = row; bad[key] = value; #expect(!pass(bad))
        }
        row["receivers"] = [sibling,target]
        #expect(!pass(row))
    }

    @Test func wrongNonceOrGenericRegistrationStopsBeforeFixtureLaunch() throws {
        let nonce = UUID()
        for pin: JSON in [["challenge":UUID().uuidString,"kind":"interactiveWindowPair","cdhash":String(repeating:"a",count:40)],
                          ["challenge":nonce.uuidString,"kind":"registered-window","cdhash":String(repeating:"a",count:40)],
                          ["challenge":nonce.uuidString,"kind":"interactiveWindowPair","cdhash":"bad"]] {
            let bytes = try JSONSerialization.data(withJSONObject:pin)
            #expect(throws:(any Error).self) { try StageInteractivePeer(nonce,pin:bytes,hostBirth:12,hostHash:"test",login:53) }
        }
    }
}
