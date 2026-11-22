import CoreGraphics
import Foundation
import Testing
@testable import NearpaneHost

struct StageInstalledProbeTests {
    @MainActor @Test func stripSamplesAreBoundedAndRequireARealNonoverlappingRow() {
        let display = CGRect(x:0, y:0, width:1440, height:900)
        let points = StageOverviewHitTest.positions(in: display)
        #expect(!points.isEmpty && points.count <= 200)
        #expect(points.allSatisfy { display.contains($0) && $0.y < 160 })
        let a = CGRect(x:100,y:20,width:80,height:50)
        #expect(StageOverviewHitTest.validLayout([a, a.offsetBy(dx:90,dy:1)], in:display))
        #expect(!StageOverviewHitTest.validLayout([], in:display))
        #expect(!StageOverviewHitTest.validLayout([a,a], in:display))
        #expect(!StageOverviewHitTest.validLayout([a,a.offsetBy(dx:90,dy:60)], in:display))
        #expect(!StageOverviewHitTest.validLayout([a.offsetBy(dx:-190,dy:0)], in:display))
    }
    @MainActor @Test func fullscreenSupplementRequiresTwoMatchingDisplaySessionAndSpaceReads() {
        let current: [String:Any] = ["type":4,"malformed":false,"id64":42,"managedID":42,"uuid":UUID().uuidString]
        let sample: [String:Any] = ["current":current,"directCurrent":42,"directCurrentAfter":42,
            "matchingRosterEntries":[current],"display":["topologyConfirmed":true,"activeCGCount":1,"primaryUUID":UUID().uuidString] as [String:Any],
            "session":["qualified":true]]
        var report: [String:Any] = ["scope":["reason":"fullscreenType4"],"workspace":["notificationsObserved":0],"samples":[sample,sample]]
        #expect(StageCanaryOverview.fullscreenReadOnlyIdentity(report) != nil)
        var conflicting = sample
        conflicting["directCurrentAfter"] = 17
        report["samples"] = [sample,conflicting]
        #expect(StageCanaryOverview.fullscreenReadOnlyIdentity(report) == nil)
        report["samples"] = [sample,sample]
        report["workspace"] = ["notificationsObserved":1]
        #expect(StageCanaryOverview.fullscreenReadOnlyIdentity(report) == nil)
    }
    @MainActor @Test func overviewRequiresTheExactVisibleOrdinaryFocusedWindow() {
        let window: CGWindowID = 32
        let pid: pid_t = 77
        let layer = kCGWindowLayer as String, visible = kCGWindowIsOnscreen as String, alpha = kCGWindowAlpha as String
        let row: [String: Any] = [kCGWindowOwnerPID as String: pid, kCGWindowNumber as String: window,
                                  layer: 0, visible: true, alpha: 1.0]
        #expect(StageCanaryOverview.matchesForeground([row], pid: pid, number: window))
        for change: [String: Any] in [[layer: 8], [visible: false], [alpha: 0.0],
                                      [kCGWindowOwnerPID as String: pid + 1], [kCGWindowNumber as String: window + 1]] {
            let changed = row.merging(change) { _, new in new }
            #expect(!StageCanaryOverview.matchesForeground([changed], pid: pid, number: window))
        }
        #expect(!StageCanaryOverview.matchesForeground([], pid: pid, number: window))
        #expect(!StageCanaryOverview.matchesForeground([row, row], pid: pid, number: window))
    }

    private func makeReport(registered: Bool = false, scope: UInt64 = 42, displayCount: UInt32 = 1,
                            login: UInt32 = 91, post: Bool = true, reverse: Bool = true) -> [String: Any] {
        let d: [String: Any] = ["topologyConfirmed": true, "activeCGCount": displayCount, "primaryUUID": "fixture-display"]
        let session: [String: Any] = ["qualified": true, "securitySessionID": login]
        let sample: [String: Any] = ["display": d, "session": session]
        let member: [String: Any] = ["status": registered ? "PASS" : "NOT_RUN", "spaceToWindow": ["status":"PASS"],
                                     "windowToSpaces": ["status":reverse ? "PASS" : "UNKNOWN"]]
        return ["spaceScope": ["scope": ["status":"PASS","nativeID":scope] as [String:Any],
                               "fixtureMembership":member,"samples":[sample,sample]] as [String:Any],
                "permissions":["accessibility":true,"listenEvent":true,"screenCapture":true,"postEvent":post],
                "system":["build":"26A428","sip":["enabled":true]] as [String:Any]]
    }

    @Test func cycleNeedsOneUnchangedPhysicalSessionAndBothRegisteredMembershipDirections() {
        let before = makeReport()
        let check = StageEnginePackageProbe.admitsInstalledCycle
        #expect(check(before, makeReport(registered:true)))
        #expect(!check(nil, makeReport(registered:true)))
        #expect(!check(before, makeReport()))
        #expect(!check(before, makeReport(registered:true, scope:43)))
        #expect(!check(before, makeReport(registered:true, displayCount:2)))
        #expect(!check(before, makeReport(registered:true, login:92)))
        #expect(!check(before, makeReport(registered:true, post:false)))
        #expect(!check(before, makeReport(registered:true, reverse:false)))
    }

    @Test func ownPanelChecksThePhysicalScopeWithoutEnrollingAnExternalWindow() {
        let before = makeReport()
        let check = StageEnginePackageProbe.admitsPhysicalScope
        #expect(check(before, makeReport()))
        #expect(!check(before, makeReport(scope: 43)))
        #expect(!check(before, makeReport(login: 92)))
        #expect(!check(before, makeReport(displayCount: 2)))
        #expect(!StageEnginePackageProbe.admitsInstalledCycle(preflight: before, registered: makeReport()))
    }

    @Test @MainActor func nonceRendezvousDoesNotReadLinksAndStopsBeforeFixtureOnAbort() async throws {
        let nonce = UUID()
        let directory = URL(fileURLWithPath:"/private/tmp/nearpane-host-scope." + nonce.uuidString.lowercased())
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,
                                                attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:directory) }
        let reply = try StageScopeReply(nonce)
        #expect(try !reply.exists(.launch))
        try reply.finish(Data("first\n".utf8),preflight:true)
        #expect(FileManager.default.fileExists(atPath:directory.appendingPathComponent("preflight.json").path))
        #expect(!FileManager.default.fileExists(atPath:directory.appendingPathComponent("response.json").path))
        try FileManager.default.createSymbolicLink(atPath:directory.appendingPathComponent("launched").path,
                                                   withDestinationPath:directory.appendingPathComponent("preflight.json").path)
        #expect(throws: (any Error).self) { try reply.exists(.launch) }
        let madeAbort = FileManager.default.createFile(atPath:directory.appendingPathComponent("abort").path,
                                                       contents:Data(),attributes:[.posixPermissions:0o600])
        try #require(madeAbort)
        await #expect(throws: CancellationError.self) { try await reply.wait(for:.registration,seconds:1) }
    }
}
