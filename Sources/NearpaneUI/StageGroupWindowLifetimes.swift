import NearpaneCore
import Foundation

/// AX can retain the original window across an engine hide. A new sidebar appearance still has
/// its own input and capture token. Only group membership may reuse the proved AX lifetime.
struct StageGroupWindowLifetimes {
    private struct Binding { let appearance: UUID, group: UUID }
    private var bindings = [DesktopWindowKey: Binding]()

    func lifetime(of key: DesktopWindowKey, appearance: UUID?) -> UUID? {
        guard let appearance else { return nil }
        guard let binding = bindings[key], binding.appearance == appearance else { return appearance }
        return binding.group
    }

    mutating func prune(_ observed: [DesktopWindowKey: UUID]) {
        bindings = bindings.filter { observed[$0.key] == $0.value.appearance }
    }

    mutating func confirm(first: StageWindowSample, second: StageWindowSample, previousAppearances: [DesktopWindowKey: UUID],
                          appearances: [DesktopWindowKey: UUID], enrolled: [NativeSpaceWindow: UUID]) {
        guard first.scope == second.scope, first.generation == second.generation, first.sequence < second.sequence,
              let native = first.nativeID, native > 0, second.nativeID == native, first.workArea == second.workArea else { return }
        for (window, lifetime) in enrolled {
            let key = DesktopWindowKey(pid: window.pid, birth: window.birth, number: window.number)
            guard let appearance = appearances[key], previousAppearances[key] == appearance, appearance != lifetime, let state = first.windows[window],
                  state.window == window, state.visibility == .visible, state.hiddenSpaceID == nil,
                  state.lifetime == lifetime, second.windows[window] == state else { continue }
            bindings[key] = .init(appearance: appearance, group: lifetime)
        }
    }
}
