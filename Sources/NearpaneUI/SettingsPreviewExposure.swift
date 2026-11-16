import Foundation
import Observation
import NearpaneCore

/// A retained Settings hosting view is not evidence of a visible window. Withdrawing
/// the window synchronously discards its private selection and unsigned preview.
@Observable @MainActor public final class SettingsPreviewExposure {
    @ObservationIgnored private var visible = false
    @ObservationIgnored private weak var selection: AdmissionSelection?
    @ObservationIgnored private weak var glassHost: HostSession?
    @ObservationIgnored private var glassDisplay: String?
    private(set) var glassWithdrawal: UInt64 = 0

    public init() {}
    public func update(visible: Bool, miniaturized: Bool, appHidden: Bool, sessionUnavailable: Bool) {
        self.visible = visible && !miniaturized && !appHidden && !sessionUnavailable
        if !self.visible { withdraw() }
    }
    public func withdraw() {
        visible = false
        selection?.close()
        selection = nil
        if let glassDisplay {
            glassHost?.previewGlass(nil, on: glassDisplay)
            self.glassDisplay = nil
            glassHost = nil
            glassWithdrawal += 1
        }
    }
    func previewGlass(_ value: PanelGlassSettings?, host: HostSession, display: String) {
        guard value == nil || visible else { return }
        if value != nil, let previous = glassDisplay, previous != display {
            glassHost?.previewGlass(nil, on: previous)
        }
        host.previewGlass(value, on: display)
        if value != nil { glassHost = host; glassDisplay = display }
        else if glassDisplay == display { glassHost = nil; glassDisplay = nil }
    }
    func open(_ next: AdmissionSelection) -> Bool {
        guard visible else { return false }
        if let selection, selection !== next { selection.close() }
        selection = next
        return true
    }
}
