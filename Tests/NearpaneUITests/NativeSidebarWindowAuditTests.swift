import Foundation
import CoreMedia
@preconcurrency import ScreenCaptureKit
import SwiftUI
import NearpaneCore
@testable import NearpaneUI
import Testing

@MainActor struct NativeSidebarWindowAuditTests {
    @Test func requiresPrivateIsolatedHomeAndExplicitNumericAllowlistAndRejectsForeignEvents() throws {
        let fm = FileManager.default
        let caches = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let parent = caches.appendingPathComponent("nearpane-native-acceptance.owned")
        let home = parent.appendingPathComponent("home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: caches) }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        #expect(NativeSidebarWindowAudit(environment: [:], cachesForTesting: caches) == nil)
        #expect(NativeSidebarWindowAudit(environment: ["CFFIXED_USER_HOME": caches.path], cachesForTesting: caches) == nil)
        let audit = try #require(NativeSidebarWindowAudit(environment: ["CFFIXED_USER_HOME": home.path], cachesForTesting: caches))
        let feed = UUID(), epoch = UUID(), listed = NativeSpaceWindow(pid: 100, birth: 101, number: 102)
        #expect(audit.sample(feed: feed, epoch: epoch, revision: 1) == nil)
        let manifest = home.appendingPathComponent("p0-window-audit-targets.json")
        try Data(#"{"version":1,"targets":[{"pid":100,"birth":101,"number":102}]}"#.utf8).write(to: manifest)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: manifest.path)
        #expect(audit.sample(feed: feed, epoch: epoch, revision: 1) == nil)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
        let evidence = try #require(audit.sample(feed: feed, epoch: epoch, revision: 8))
        #expect(evidence.targets == [listed])
        let log = home.appendingPathComponent("p0-window-audit.jsonl")
        evidence.event("disallowed", window: .init(pid: 100, birth: 999, number: 102))
        #expect(!fm.fileExists(atPath: log.path))
        evidence.event("test", window: listed)
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 1)
        let record = try #require(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        #expect(record["writerPID"] as? Int32 == getpid() && record["stage"] as? String == "test")
        #expect(record["revision"] as? Int == 8 && record["uptime"] is Double)
        try fm.removeItem(at: manifest)
        try fm.createSymbolicLink(at: manifest, withDestinationURL: log)
        #expect(audit.sample(feed: feed, epoch: epoch, revision: 9) == nil)
    }

    @Test func previewTransitionsBindOnlyTwoTargetsAndWithdrawBeforeAStaleCallbackWrites() throws {
        let fm = FileManager.default
        let caches = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let parent = caches.appendingPathComponent("nearpane-native-acceptance.trace")
        let home = parent.appendingPathComponent("home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: caches) }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        let plain = ["CFFIXED_USER_HOME": home.path]
        let on = plain.merging(["NEARPANE_TEST_HOME": home.path, "NEARPANE_PREVIEW_DIAGNOSTICS": "1"]) { _, new in new }
        #expect(NativeSidebarWindowAudit(environment: plain, cachesForTesting: caches)?.previewTrace == nil)
        #expect(NativeSidebarWindowAudit(environment: on.merging(["NEARPANE_TEST_HOME": caches.path]) { _, v in v },
                                         cachesForTesting: caches)?.previewTrace == nil)
        let selected = NativeSidebarWindowAudit(environment: on, cachesForTesting: caches, verifyTrace: { r, targets in
            r.hostPID == getpid() && r.hostBirth == 101 && targets.count == 2 && targets.allSatisfy { $0.pid == 200 && $0.birth == 300 }
        })
        let audit = try #require(selected)
        let trace = try #require(audit.previewTrace)
        let a = DesktopWindowKey(pid: 200, birth: 300, number: 401), b = DesktopWindowKey(pid: 200, birth: 300, number: 402)
        let wrong = DesktopWindowKey(pid: 200, birth: 999, number: 401)
        let feed = UUID(), epoch = UUID()
        let manifest = home.appendingPathComponent("p0-window-audit-targets.json")
        let file = home.appendingPathComponent("p0-preview-transitions.jsonl")
        let request = PreviewPipelineAudit.Request(token: UUID(), hostPID: getpid(), hostBirth: 101, hostHash: "test", fixtureHash: "test")
        struct Enrollment: Encodable { let version: Int, targets: [NativeSpaceWindow]; let previewTrace: PreviewPipelineAudit.Request }
        func bind(_ keys: [DesktopWindowKey]) throws {
            let m = Enrollment(version: 1, targets: keys.map { .init(pid: $0.pid, birth: $0.birth, number: $0.number) }, previewTrace: request)
            try JSONEncoder().encode(m).write(to: manifest, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
            _ = audit.sample(feed: feed, epoch: epoch, revision: 7)
        }
        func records() throws -> [[String: Any]] {
            trace.drainForTesting()
            return try Data(contentsOf: file).split(separator: 10).map {
                try #require(JSONSerialization.jsonObject(with: $0) as? [String: Any])
            }
        }
        try bind([a])
        trace.record(a, .cache, .current); trace.drainForTesting()
        #expect(!fm.fileExists(atPath: file.path))
        try bind([a,b])
        for _ in 0..<100 { trace.record(a, .cache, .current, epoch: 0, sequence: 2) }
        trace.record(wrong, .lookup, .sharingDenied)
        trace.record(.init(pid: 201, birth: 300, number: 401), .cache, .removed)
        trace.record(.init(pid: 200, birth: 300, number: 403), .card, .outline)
        let (stream, continuation) = AsyncStream<WindowFrameStream.Update>.makeStream(bufferingPolicy: .bufferingNewest(1))
        _ = stream
        let output = WindowFrameStream.Output(continuation, width: 2, height: 2, diagnostic: .init(audit: trace, key: b))
        var control: CMSampleBuffer?
        #expect(CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: true, makeDataReadyCallback: nil,
            refcon: nil, formatDescription: nil, sampleCount: 0, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &control) == noErr)
        let sample = try #require(control)
        output.receive(sample, status: .blank, now: 100)
        #expect(output.epoch == 1)
        output.receive(sample, status: .suspended, now: 101)
        #expect(output.epoch == 2)
        continuation.finish()
        let gallery = DesktopWindowGallery(permitsWindow: { _ in true }, audit: trace, lifetime: { _ in nil })
        let card = CurrentWindowCard(label: "fixture", badge: nil, size: .init(width: 60, height: 40), target: nil,
            key: b, gallery: gallery, permitted: true, border: 0, fontSize: 10, selected: { nil }, describe: { $0 }, select: {}, selectable: true)
        #expect(ImageRenderer(content: card.frame(width: 60)).cgImage != nil)
        let before = try records()
        #expect(before.compactMap { $0["reason"] as? String } == ["enrolled", "enrolled", "current", "blank", "suspended", "outline"])
        #expect(before[3]["uptime"] as? Double == 100 && before[3]["streamEpoch"] as? Int == 1)
        #expect(before[4]["uptime"] as? Double == 101 && before[4]["streamEpoch"] as? Int == 2)
        #expect(before[2]["frameSequence"] as? Int == 2)
        _ = audit.sample(feed: feed, epoch: UUID(), revision: 8)
        for i in 0..<700 { trace.record(b, .card, i.isMultiple(of: 2) ? .liveImage : .outline) }
        let capped = try records()
        #expect(capped.count == Int(PreviewPipelineAudit.limit) + 1 && capped.last?["reason"] as? String == "capacityReached")
        #expect(capped.last?["revision"] as? Int == 8)
        // Re-enroll by a new private inode and then remove the manifest before a pending callback.
        try bind([a,b])
        let prior = try records().count
        try fm.removeItem(at: manifest)
        trace.record(b, .lookup, .sharingDenied)
        #expect(try records().count == prior)
        #expect(audit.sample(feed: feed, epoch: epoch, revision: 9) == nil)
    }
}
