import Foundation
import Testing
import NearpaneCore
@testable import NearpaneUI

struct EnrolledFullscreenObservationTests {
    let run = UUID(), date = Date(timeIntervalSince1970: 1000)
    let before = ["main":"101", "side":"202"]

    @Test func enrolledExecutableAcceptsSystemTemporaryAliasOnlyForSamePhysicalFile() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let exe = root.appendingPathComponent("witness")
        let link = root.appendingPathComponent("link")
        try Data().write(to: exe)
        try fm.createSymbolicLink(at: link, withDestinationURL: exe)
        let matches = EnrolledFullscreenObservation.matchesExecutablePath
        #expect(matches(exe.path, exe.path))
        #expect(matches(exe.path, "/tmp/" + root.lastPathComponent + "/witness"))
        #expect(!matches(link.path, link.path))
        #expect(!matches(exe.path, link.path))
        #expect(!matches("/tmp/" + root.lastPathComponent + "/witness", exe.path))
        try fm.removeItem(at: exe)
        try fm.createSymbolicLink(at: exe, withDestinationURL: root)
        #expect(!matches(exe.path, exe.path))
    }

    func challenge() throws -> EnrolledFullscreenObservation {
        let facts: [String:Any] = ["run": run.uuidString, "token": UUID().uuidString, "pid":115, "launch":2002,
            "number":29, "display":"side", "source":"202", "fullscreenCurrent":"303", "revision":6,
            "build":"test-build", "boot":"test-boot", "expiresUptime":34.0, "witnessSHA256":"w", "readerSHA256":"r"]
        return try JSONDecoder().decode(EnrolledFullscreenObservation.self, from:JSONSerialization.data(withJSONObject:facts))
    }

    func snapshot(full: Bool, primary: String = "101", window: UInt32 = 29, launch: UInt64 = 2002,
                  display: String = "side", membership: String? = nil, ax: UInt32 = 29) -> DesktopSnapshot {
        let frame = SurfaceRect(x: -600, y:0, width:600, height:840)
        let main = DisplayObservation(id:"main",frame:.init(width:1200,height:700),rotationDegrees:0,backingScale:2,usable:.init(width:1200,height:700))
        let side = DisplayObservation(id:"side",frame:frame,rotationDegrees:90,backingScale:2,usable:.init(width:600,height:840))
        let row = ObservedSpaceRow(displayID:display,scopeID:"secondary",recordID:"202",anchor:.init(number:window,displayID:display,globalFrame:frame))
        let request = DesktopReadRequest(session:run,revision:7,parentPID:115,fixtureWindows:[window],anchors:full ? [] : [row.anchor],experimentalSpaces:true)
        let observation = WindowObservation(id:"sample",displayID:display,bounds:.init(width:600,height:840),
            membership:.known(recordIDs:[membership ?? (full ? "303" : "202")]),confidence:.geometryOnly,
            metadata:.init(number:window,pid:115,launchMicroseconds:launch,element:UUID(),globalFrame:frame,frontToBack:0,
                           minimized:false,fullScreen:full,axFrame:frame,isOnscreen:true,axStandardWindowNumber:ax))
        return .observed(request,from:date,to:date,build:"test-build",topology:"two",consistent:true,separateSpaces:true,
            displays:[main,side],scopes:[.init(id:"first",displayID:"main",records:[.init(id:primary,isCurrent:true)]),
                .init(id:"secondary",displayID:"side",records:[.init(id:"202",isCurrent:!full),.init(id:"303",isCurrent:full)])],
            windows:[observation], evidence:.init(population:.markedFixture,accessibility:.available,spaces:.observed,
                                                 rows:full ? [] : [row],windowLimitReached:false,beganUptime:27,endedUptime:28))
    }

    @Test func sameNativeClassifierAndUniqueMembershipRequiredForEntryAndReturn() throws {
        let c = try challenge()
        let n = snapshot(full:true)
        let sample = try #require(c.sample(n, sourceCurrents:before, returned:false, date:date, uptime:29,validUntil:34))
        #expect(sample.observation == n.fullscreenObservation(for:"side",now:date,uptime:29))
        #expect(sample.validUntil == 31)
        let a = snapshot(full:false)
        #expect(c.sample(a,sourceCurrents:before,returned:true,date:date,uptime:29,validUntil:34)?.observation == .ordinary(workspace:a.workspaceID(display:"side",record:"202")))
        for (s, returned) in [(n,true), (a,false), (snapshot(full:true,primary:"elsewhere"),false),
                              (snapshot(full:true,window:30),false), (snapshot(full:true,launch:4004),false),
                              (snapshot(full:true,membership:"202"),false), (snapshot(full:true,ax:9),false)] {
            #expect(c.sample(s,sourceCurrents:before,returned:returned,date:date,uptime:29,validUntil:34) == nil)
        }
    }
    @Test func expiredOtherRunOrUnwitnessedSourceDoesNotPresentTool() throws {
        let c = try challenge()
        var s = snapshot(full:true)
        #expect(c.sample(s,sourceCurrents:before,returned:false,date:date,uptime:31,validUntil:34) == nil)
        #expect(c.sample(s,sourceCurrents:before,returned:false,date:date,uptime:29,validUntil:29) == nil)
        s.sessionID = UUID()
        #expect(c.sample(s,sourceCurrents:before,returned:false,date:date,uptime:29,validUntil:34) == nil)
        s = snapshot(full:false); s.native?.rows = []; s.userSpaceSemantics = .unknown
        #expect(c.sample(s,sourceCurrents:before,returned:true,date:date,uptime:29,validUntil:34) == nil)
    }
}
