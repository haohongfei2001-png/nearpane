import Foundation
import Testing
@testable import NearpaneCore

struct WorkbenchVisualPolicyTests {
    @Test func retiredGeometryIsPreservedWithoutRemainingAnActiveOverride() throws {
        var legacy = DisplaySettings()
        legacy.measures = [.reservedWidth: .init(18, .percent), .panelHeight: .init(500),
            .voiceHeight: .init(300), .textSize: .init(21), .labelSize: .init(15),
            .cornerRadius: .init(38), .copySize: .init(30)]
        legacy.glass.overallTransparency = 35
        legacy.glass.outerTransparency = 60
        legacy.glass.innerTransparency = 20
        legacy.glass.rimWidth = .init(24)
        legacy.edge = .left
        legacy.anchor = .bottom
        legacy.placement = .floating
        legacy.floatingPosition = .init(x: 100, y: 140)
        legacy.policy = .pinned
        let current = legacy.applyingWorkbenchVisualPolicy()
        #expect(current.visualStyleRevision == WorkbenchVisualPolicy.revision)
        #expect(current.measures == [.panelWidth: .init(18, .percent), .textSize: .init(16), .labelSize: .init(12)])
        #expect(current.retiredVisualOverrides == legacy.measures)
        #expect(current.glass.overallTransparency == 35)
        #expect(current.glass.outerTransparency == nil && current.glass.innerTransparency == nil && current.glass.rimWidth == nil)
        #expect(current.retiredGlassOverrides == legacy.glass)
        #expect(current.edge == legacy.edge && current.anchor == legacy.anchor && current.placement == legacy.placement)
        #expect(current.floatingPosition == legacy.floatingPosition && current.policy == legacy.policy)
        #expect(current.fullscreenTools == legacy.fullscreenTools && current.toolAnchor == legacy.toolAnchor)
        #expect(current.applyingWorkbenchVisualPolicy() == current)
        let data = try JSONEncoder().encode(current)
        let decoded = try JSONDecoder().decode(DisplaySettings.self, from: data)
        #expect(decoded == current)
    }

    @Test func widthUsesTheActualDisplayWithBoundedControlsAndNoSeparateReservation() {
        var settings = DisplaySettings()
        settings.measures[.panelWidth] = .init(18, .percent)
        settings = settings.applyingWorkbenchVisualPolicy()
        #expect(WorkbenchVisualPolicy.width(in: 1440, settings: settings) == 259.2)
        #expect(WorkbenchVisualPolicy.width(in: 5120, settings: settings) == 420)
        #expect(WorkbenchVisualPolicy.width(in: 180, settings: settings) == 180)
        #expect(WorkbenchVisualPolicy.widthRange(in: .infinity) == 0...0)
        settings.measures[.panelWidth] = .init(1)
        #expect(WorkbenchVisualPolicy.width(in: 1440, settings: settings) == 220)
        settings.measures[.panelWidth] = .init(900)
        #expect(WorkbenchVisualPolicy.width(in: 1440, settings: settings) == 420)
    }

    @MainActor @Test func migrationDoesNotWriteUntilAnExistingUserActionSavesAndKeepsOtherChoices() async {
        var original = HostConfiguration()
        original.accent = .teal
        original.edge = .left
        original.preferredDisplayID = "saved-display"
        original.clockTimeZoneID = "Asia/Shanghai"
        original.modules = [.init(id: BuiltinCatalog.screenshots, enabled: false),
                            .init(id: BuiltinCatalog.voice, enabled: true)]
        var display = DisplaySettings()
        display.measures[.voiceHeight] = .init(280)
        display.measures[.panelWidth] = .init(260)
        original.displays["saved-display"] = display
        let store = MemoryConfigurationStore(original)
        let host = HostSession(store: store, includeSampleModules: false)
        await host.start()
        defer { host.stop() }
        #expect(store.value == original)
        #expect(host.configuration.modules == original.modules)
        #expect(host.configuration.accent == .teal && host.configuration.edge == .left)
        #expect(host.configuration.preferredDisplayID == original.preferredDisplayID)
        #expect(host.configuration.clockTimeZoneID == original.clockTimeZoneID)
        #expect(host.configuration.displays["saved-display"]?.measures[.voiceHeight] == nil)
        #expect(host.configuration.displays["saved-display"]?.retiredVisualOverrides[.voiceHeight] == .init(280))
        host.setAccent(.orange)
        #expect(store.value.displays["saved-display"]?.retiredVisualOverrides[.voiceHeight] == .init(280))
        #expect(store.value.modules == original.modules)
    }

    @Test func retainedValuesRemainSubjectToConfigurationValidation() {
        var configuration = HostConfiguration()
        var display = DisplaySettings().applyingWorkbenchVisualPolicy()
        display.measures[.textSize] = .init(14)
        display.retiredVisualOverrides[.textSize] = .init(.infinity)
        configuration.displays["screen"] = display
        #expect(throws: ConfigurationError.self) { try configuration.validated() }
    }
}
