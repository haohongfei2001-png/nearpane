import AppKit
import Foundation
import LyricServices
import Testing
@testable import LyricUI

@Suite("Native auxiliary window layout", .serialized)
@MainActor
struct AuxiliaryLayoutTests {
    @Test(arguments: [false, true])
    func welcomeAndSettingsKeepTheirDesignedContentSize(dark: Bool) async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LyricAuxiliary-" + UUID().uuidString)
        let defaultsName = "LyricAuxiliary.test." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: directory)
        }
        var settings = LyricSettings()
        settings.onlineLyrics = false
        settings.save(to: defaults)
        let model = LyricAppModel(repository: LyricRepository(storageURL: directory, onlineEnabled: false), defaults: defaults)
        let controller = LyricAuxiliaryController(model: model)
        defer { controller.closeAll() }

        for page in [LyricAuxiliaryPage.welcome, .settings] {
            model.show(page)
            let window = try #require(NSApp.windows.first { $0.title == page.title && $0.isVisible })
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            // Allow hosting's deferred minimum/ideal-size propagation to settle;
            // checking only the constructor's frame missed the CI36 regression.
            try await Task.sleep(for: .milliseconds(120))
            window.contentView?.layoutSubtreeIfNeeded()
            let expected = page == .welcome ? NSSize(width: 400, height: 360) : NSSize(width: 450, height: 620)
            #expect(window.contentView?.bounds.size == expected)
            #expect(!window.styleMask.contains(.resizable))
            // Hosting is free to clear its own sizing hints. The contract is the
            // actual settled content, including when an existing page is shown.
            controller.show(page)
            try await Task.sleep(for: .milliseconds(120))
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(window.contentView?.bounds.size == expected)
            let layout = LyricNativeSmoke.auxiliaryLayout(window: window, page: page)
            #expect(layout["layoutPassed"] as? Bool == true)
            if page == .welcome {
                #expect((layout["contentRegions"] as? [[String: Any]])?.count == 5)
                #expect(layout["contentWithinBounds"] as? Bool == true)
                #expect(layout["contentRegionsDoNotOverlap"] as? Bool == true)
            }
            #expect(model.snapshot.selection == nil)
            #expect(!model.ownsSession)
            controller.closeAll()
        }
    }

    @Test func oversizedMountedWelcomeFailsLayoutAcceptance() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 2157),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let layout = LyricNativeSmoke.auxiliaryLayout(window: window, page: .welcome)
        #expect(layout["sizeMatchesDesign"] as? Bool == false)
        #expect(layout["layoutPassed"] as? Bool == false)
    }
}
