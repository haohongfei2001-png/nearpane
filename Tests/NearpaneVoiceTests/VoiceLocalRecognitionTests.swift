import Foundation
import SaytileKit
import Testing
@testable import NearpaneVoice

@MainActor struct VoiceLocalRecognitionTests {
    @Test func isolatedInputCanFallBackWithoutOpeningAnotherProfileOrDownloading() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let model = VoiceLocalRecognition(directory: folder, allowDownloads: false)
        #expect(VoiceLocalRecognition.preferred == LocalModelRecommendation.preferred)
        await model.refresh()
        await model.prepareForInput()
        model.resume()
        #expect(model.selection == .apple)
        #expect(model.status?.downloading == false)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func checkingModelReadinessNeverStartsAFirstTimeDownload() async {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let model = VoiceLocalRecognition(directory: folder, allowDownloads: true)
        await model.refresh()
        #expect(model.selection == .apple)
        #expect(model.status?.downloading == false)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func profileIdentitySurvivesCreatingAPreviouslyMissingHierarchy() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let nested = root.appending(path: "Nearpane/Voice")
        let before = VoiceRecognitionProfile.identifier(for: nested)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(before == VoiceRecognitionProfile.identifier(for: nested))
        #expect(before != VoiceRecognitionProfile.identifier(for: root.appending(path: "Other/Voice")))
    }
}
