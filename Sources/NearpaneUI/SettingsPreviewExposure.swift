import Foundation

/// A retained Settings hosting view is not evidence of a visible window. Withdrawing
/// the window synchronously discards its private selection and unsigned preview.
@MainActor public final class SettingsPreviewExposure {
    private var visible = false
    private weak var selection: AdmissionSelection?

    public init() {}
    public func update(visible: Bool, miniaturized: Bool, appHidden: Bool, sessionUnavailable: Bool) {
        self.visible = visible && !miniaturized && !appHidden && !sessionUnavailable
        if !self.visible { withdraw() }
    }
    public func withdraw() {
        visible = false
        selection?.close()
        selection = nil
    }
    func open(_ next: AdmissionSelection) -> Bool {
        guard visible else { return false }
        if let selection, selection !== next { selection.close() }
        selection = next
        return true
    }
}
