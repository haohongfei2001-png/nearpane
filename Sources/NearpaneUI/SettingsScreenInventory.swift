import NearpaneCore
import Observation

/// Updating the display list should never replace a Settings window or its current tab.
@Observable @MainActor public final class SettingsScreenInventory {
    public private(set) var screens: [ScreenGeometry] = []
    public init() {}
    public func update(_ current: [ScreenGeometry]) {
        if current != screens { screens = current }
    }
    public func contains(_ expected: ScreenGeometry) -> Bool {
        screens.filter { $0.id == expected.id } == [expected]
    }
}
