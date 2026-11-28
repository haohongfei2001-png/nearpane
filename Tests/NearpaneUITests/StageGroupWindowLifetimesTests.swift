import Foundation
import Testing
import NearpaneCore
@testable import NearpaneUI

@MainActor struct StageGroupWindowLifetimesTests {
    let key = DesktopWindowKey(pid: 120, birth: 3400, number: 70)
    let scope = StageGroupScope(display: UUID(), nativeSpace: UUID()), generation = UUID()
    let groupLife = UUID(), appearance = UUID(), work = SurfaceRect(width: 800, height: 600)
    var id: NativeSpaceWindow { .init(pid: key.pid, birth: key.birth, number: key.number) }

    func sample(_ sequence: UInt64, life: UUID? = nil, visible: Bool = true, generation: UUID? = nil, native: UInt64 = 4) -> StageWindowSample {
        let state = StageWindowState(window: id, lifetime: life ?? groupLife, frame: .init(width: 300, height: 200),
                                     visibility: visible ? .visible : .parked)
        return .init(scope: scope, generation: generation ?? self.generation, sequence: sequence, workArea: work,
                     windows: [id: state], focus: id, nativeID: native)
    }

    @Test func restoredOriginalKeepsItsGroupWithoutRevalidatingOldInput() throws {
        let store = StageGroupStore(profile: nil)
        func live(_ token: UUID) -> StageGroupWindow {
            .init(display: scope.display, identity: id, lifetime: token, nativeSpace: scope.nativeSpace)
        }
        try store.observe([live(groupLife)])
        let original = try #require(store.groups(in: scope).first?.id)
        let input = [key: appearance]
        var bindings = StageGroupWindowLifetimes()
        #expect(store.projectedGroups(on: scope.display, among: [live(appearance)]).isEmpty)
        bindings.confirm(first: sample(10), second: sample(11), previousAppearances: input, appearances: input, enrolled: [id: groupLife])
        let stable = try #require(bindings.lifetime(of: key, appearance: input[key]))
        #expect(store.projectedGroups(on: scope.display, among: [live(stable)]).map(\.id) == [original])
        #expect(input[key] == appearance && input[key] != groupLife)
        bindings.prune([:])
        #expect(bindings.lifetime(of: key, appearance: nil) == nil)
        #expect(bindings.lifetime(of: key, appearance: appearance) == appearance)
    }

    @Test func incompleteOrChangedWitnessNeverRebindsAReusedWindowNumber() {
        let input = [key: appearance]
        for next in [sample(1), sample(2, life: UUID()), sample(2, visible: false), sample(2, generation: UUID()), sample(2, native: 7)] {
            var bindings = StageGroupWindowLifetimes()
            bindings.confirm(first: sample(1), second: next, previousAppearances: input, appearances: input, enrolled: [id: groupLife])
            #expect(bindings.lifetime(of: key, appearance: appearance) == appearance)
        }
        var unconfirmed = StageGroupWindowLifetimes()
        unconfirmed.confirm(first: sample(1), second: sample(2), previousAppearances: [key: UUID()], appearances: input, enrolled: [id: groupLife])
        unconfirmed.confirm(first: sample(1), second: sample(2), previousAppearances: input, appearances: input, enrolled: [:])
        #expect(unconfirmed.lifetime(of: key, appearance: appearance) == appearance)
    }
}
