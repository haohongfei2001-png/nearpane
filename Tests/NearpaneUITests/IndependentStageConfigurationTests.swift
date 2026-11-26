import Foundation
import Testing
@testable import NearpaneUI

@MainActor struct IndependentStageConfigurationTests {
    @Test func anAbsentProfileUnderTheSameRealDirectoryAcceptsAPathAlias() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("np-config-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let output = root.appendingPathComponent("output", isDirectory: true)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: alias, withDestinationURL: output)
        let configuration = output.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: configuration)
        let profile = alias.appendingPathComponent("profile", isDirectory: true)
        #expect(!fm.fileExists(atPath: profile.path))
        #expect(IndependentStageAcceptance.configurationDirectoriesMatch(
            configuration: configuration, output: output, profile: profile))
        #expect(IndependentStageAcceptance.configurationDirectoriesMatch(
            configuration: alias.appendingPathComponent("config.json"), output: output, profile: profile))
    }

    @Test func aRealProfileOutsideTheOutputDoesNotPassBecauseItsAliasIsInside() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("np-config-scope-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let output = root.appendingPathComponent("output", isDirectory: true)
        let other = root.appendingPathComponent("output-other", isDirectory: true)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        let configuration = output.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: configuration)
        let profile = output.appendingPathComponent("profile", isDirectory: true)
        try fm.createSymbolicLink(at: profile, withDestinationURL: other)
        #expect(!IndependentStageAcceptance.configurationDirectoriesMatch(
            configuration: configuration, output: output, profile: profile))
        #expect(!IndependentStageAcceptance.configurationDirectoriesMatch(
            configuration: configuration, output: output, profile: other.appendingPathComponent("profile")))
        #expect(!IndependentStageAcceptance.configurationDirectoriesMatch(
            configuration: other.appendingPathComponent("config.json"), output: output,
            profile: output.appendingPathComponent("new-profile")))
    }
}
