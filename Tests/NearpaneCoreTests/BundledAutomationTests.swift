import Foundation
import Testing
@testable import NearpaneCore

struct BundledAutomationTests {
    @Test func missingMetadataNeverSearchesInstalledInterpreters() {
        #expect(throws: (any Error).self) { try BundledAutomation.executable(in: Bundle(for: NSObject.self)) }
    }

    @Test func incompleteOrUnverifiedBundleIsRefused() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "org.nearpane.test.runtime", "CFBundleName": "Runtime",
                                  "CFBundlePackageType": "APPL", "NearpaneAutomationSHA256": ["Helpers/NearpaneAutomation": "bad"]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: root))
        #expect(throws: (any Error).self) { try BundledAutomation.executable(in: bundle) }
    }
}
