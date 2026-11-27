import Testing
import Foundation
import SaytileKit
@testable import NearpaneVoice

@MainActor @Suite struct VoiceArchiveTests {
    @Test func archiveUsesNaturalParagraphsSearchesOldVersionsAndKeepsThePanelSeparate() async throws {
        let dir = VoiceTests().directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SaytileStore(directory: dir)
        let module = VoiceModule(openStore: { try SaytileStore(directory: dir) }, makeInput: { _, notify in
            Issue.record("Browsing must not open the audio controller"); return ScriptedInput(notify)
        })
        try module.start(); await module.waitForTransition()
        #expect(try await module.archivePage(.latest, query: "").rows.isEmpty)
        var ids: [UUID] = []
        for time in [100, 102, 200, 300] {
            let row = try await store.createRecording(createdAt: Date(timeIntervalSince1970: Double(time)))
            let ticket = try await store.beginRecognition(recordingID: row.id)
            _ = try await store.applyRecognition(ticket: ticket, text: "原文 " + String(time), isFinal: true)
            try await store.finishRecording(id: row.id)
            ids.append(row.id)
        }
        _ = try await store.saveEdit(recordingID: ids[1], text: "用户已修订")
        try await store.saveDraft(recordingID: ids[1], text: "待核对的草稿")
        await module.refresh()
        let originalPanel = module.transcript
        let first = try await module.archivePage(.latest, query: "", limit: 2)
        #expect(first.rows.map(\.preview) == ["原文 300", "原文 200"])
        #expect(first.hasOlder && !first.hasNewer)
        let oldest = try #require(first.rows.last)
        let next = try await module.archivePage(.ending(at: oldest.id - 1), query: "", limit: 2)
        #expect(next.rows.count == 1 && next.hasNewer && !next.hasOlder)
        let paragraph = try #require(next.rows.first)
        #expect(paragraph.paragraph.memberCount == 2)
        let page = try await module.archiveMembers(of: paragraph.id, window: .starting(at: 0), limit: 1)
        let entry = try #require(page.entries.first)
        #expect(entry.id == ids[0] && page.hasNewer)
        let following = try await module.archiveMembers(of: paragraph.id, window: .starting(at: entry.position + 1))
        #expect(following.entries.map(\.recording.text) == ["用户已修订"])
        for term in ["原文 102", "待核对", "已修订"] {
            #expect(try await module.archivePage(.latest, query: term).rows.map(\.id) == [paragraph.id])
        }
        let versions = try await module.archiveVersions(of: ids[1])
        #expect(versions.draft == "待核对的草稿")
        #expect(versions.revisions.contains(where: { $0.origin == .final && $0.text == "原文 102" }))
        #expect(versions.revisions.contains(where: { $0.origin == .userEdit && $0.text == "用户已修订" }))
        #expect(module.transcript == originalPanel && module.capture == .paused)
        module.stop(); await module.waitForTransition()
        let saved = try await module.archivePage(.latest, query: "")
        #expect(saved.rows.count == 3)
        #expect(!module.active && module.capture == .paused)
    }

    @Test func onlyTheExplicitParagraphPlaysAndCaptureIsNeverBorrowed() async throws {
        let dir = VoiceTests().directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SaytileStore(directory: dir)
        var input: ScriptedInput?
        let module = VoiceModule(openStore: { store }, makeInput: { _, notify in
            let device = ScriptedInput(notify); input = device; return device
        })
        try module.start(); await module.waitForTransition()
        var ids: [UUID] = []
        for time in [100, 102, 300] {
            let r = try await store.createRecording(createdAt: Date(timeIntervalSince1970: Double(time)))
            try await store.registerAudioChunk(recordingID: r.id, relativePath: r.id.uuidString + "/0001.caf", frames: 1600)
            try await store.finishRecording(id: r.id)
            ids.append(r.id)
        }
        let page = try await module.archivePage(.latest, query: "")
        let paragraph = try #require(page.rows.last?.paragraph)
        #expect(paragraph.hasAudio && input == nil)
        let play = try #require(module.playArchiveParagraph(paragraph))
        await play.value
        let device = try #require(input)
        #expect(device.played == Array(ids.prefix(2)) && module.archivePlaybackParagraph == paragraph.id)
        #expect(device.permissionRequests.isEmpty && module.capture == .paused)
        module.stopArchivePlayback()
        #expect(module.archivePlaybackParagraph == nil && device.playbackID == nil)
        await module.toggle(requestPermission: false)
        #expect(module.capture == .listening && module.playArchiveParagraph(paragraph) == nil)
        #expect(module.capture == .listening)
        await module.toggle(requestPermission: false)
        let immediate = try #require(module.playArchiveParagraph(paragraph))
        module.stop(); await module.waitForTransition()
        await immediate.value
        #expect(module.archivePlaybackParagraph == nil && device.playbackID == nil && device.closed)
    }
}
