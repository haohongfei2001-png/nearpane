import Foundation
import Testing
@testable import NearpaneHost

struct StageInstalledProbeTests {
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
