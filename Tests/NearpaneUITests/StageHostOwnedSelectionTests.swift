import Foundation
import Testing
import NearpaneCore
@testable import NearpaneUI

@MainActor private final class OwnedSelectionFixture {
    final class Original {}
    let engine = Original(), monitor = Original(), replacement = Original()
    let generation = UUID(), session = UUID(), scope = StageGroupScope(display: UUID(), nativeSpace: UUID())
    let group = UUID(), member = UUID(), sibling = UUID(), lifetime = UUID(), siblingLifetime = UUID()
    let window = NativeSpaceWindow(pid: 614, birth: 3400, number: 53)
    let other = NativeSpaceWindow(pid: 614, birth: 3400, number: 55)
    let frame = SurfaceRect(x: 20, y: 30, width: 320, height: 200)
    var owner: StageEngineOwner {
        .init(spacesCandidate: .init(osBuild: "fixture", engineRevision: String(repeating: "1", count: 40),
            hostCDHash: String(repeating: "2", count: 40), hardware: "fixture", topology: "fixture",
            windowClass: "ordinary-standard", sipEnabled: true), generation: generation, evidence: group)
    }
    func stamp(_ change: String? = nil) -> StageWindowEngineHost.OwnedMemberSelection {
        let identity = StageWindowEngineWitness.RetainedMemberIdentity(
            generation: change == "generation" ? UUID() : generation,
            scope: change == "scope" ? .init(display: scope.display, nativeSpace: UUID()) : scope,
            session: change == "feedSession" ? UUID() : session, topology: change == "topology" ? "changed" : "fixture",
            home: change == "home" ? 5 : 4,
            window: change == "window" ? .init(pid: window.pid, birth: window.birth + 1, number: window.number) : window,
            lifetime: change == "lifetime" ? UUID() : lifetime,
            original: ObjectIdentifier(change == "originalAX" ? replacement : monitor))
        let changedOwner = StageEngineOwner(spacesCandidate: owner.environment, generation: generation, evidence: UUID())
        return .init(owner: change == "owner" ? changedOwner : owner,
            session: ObjectIdentifier(change == "engineSession" ? replacement : engine), revision: change == "hostRevision" ? 1 : 0,
            group: change == "group" ? UUID() : group, member: change == "member" ? sibling : member,
            members: change == "memberSet" ? [member: window] : [member: window, sibling: other], identity: identity)
    }
    func state(_ key: NativeSpaceWindow, visibility: StageWindowState.Visibility = .stageSpace,
               lifetime: UUID? = nil, hidden: UInt64? = 60) -> StageWindowState {
        .init(window: key, lifetime: lifetime ?? (key == window ? self.lifetime : siblingLifetime), frame: frame,
              visibility: visibility, hiddenSpaceID: hidden)
    }
    var states: [StageWindowState] { [state(window), state(other)] }
    func sample(_ states: [StageWindowState]? = nil) -> StageWindowSample {
        let rows = states ?? self.states
        return .init(scope: scope, generation: generation, sequence: 4,
            workArea: .init(width: 900, height: 700), windows: Dictionary(uniqueKeysWithValues: rows.map { ($0.window, $0) }),
            focus: nil, nativeID: 4)
    }
    var held: StageWindowEngineHost.HeldGroup {
        // The default focus member deliberately differs from the clicked one,
        // and no historical picture/departure exists.
        .init(id: group, member: sibling, scope: scope, state: state(other), owner: owner, count: 2, departure: nil)
    }
}

@MainActor struct StageHostOwnedSelectionTests {
    @Test(arguments: ["allHidden", "minimizedSibling", "visibleSibling", "missingSibling", "unclaimedHidden", "claimedMinimized", "clickedMinimized"])
    func onlyAnEntireOriginallyBoundHiddenGroupCanCrossTheCardHandoff(_ change: String) {
        let f = OwnedSelectionFixture(), stamp = f.stamp()
        var states = f.states, claims: Set<NativeSpaceWindow> = [f.window, f.other]
        switch change {
        case "minimizedSibling": states[1] = f.state(f.other, visibility: .minimized, hidden: nil); claims.remove(f.other)
        case "visibleSibling": states[1] = f.state(f.other, visibility: .visible, hidden: nil); claims.remove(f.other)
        case "missingSibling": states.removeLast()
        case "unclaimedHidden": claims.remove(f.other)
        case "claimedMinimized": states[1] = f.state(f.other, visibility: .minimized, hidden: nil)
        case "clickedMinimized": states[0] = f.state(f.window, visibility: .minimized, hidden: nil); claims.remove(f.window)
        default: break
        }
        #expect(stamp.capturesWholeGroup(states, claimed: claims) == (change == "allHidden" || change == "minimizedSibling"))
    }

    @Test(arguments: ["none", "owner", "engineSession", "hostRevision", "generation", "scope", "feedSession", "topology",
                      "home", "window", "lifetime", "originalAX", "group", "member", "memberSet", "revoked"])
    func anExactMemberWithoutPicturesRequiresTheSameOriginalIdentityAtDequeue(_ change: String) {
        let f = OwnedSelectionFixture(), stamp = f.stamp(), held = f.held
        let current = change == "revoked" ? nil : f.stamp(change)
        let selected = stamp.parkedState(in: f.sample(), held: held, current: current)
        #expect((selected != nil) == (change == "none"))
        if let selected {
            #expect(held.departure == nil && held.member != stamp.member)
            #expect(selected.window == f.window && selected.lifetime == f.lifetime)
            #expect(selected.window != held.state.window)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["none", "revokedBinding", "newInput", "systemTakeover", "badFreshLifetime"])
    func aRealQueuedClickWaitsForThePreviousSelectionAndRevalidatesBeforeItsExactHeldRead(_ change: String) async throws {
        let f = OwnedSelectionFixture(), stamp = f.stamp(), lane = NativeSidebarNavigation()
        let entered = AsyncStream<Void>.makeStream(), release = AsyncStream<Void>.makeStream(), ended = AsyncStream<Void>.makeStream()
        defer { entered.continuation.finish(); release.continuation.finish(); ended.continuation.finish() }
        var current: StageWindowEngineHost.OwnedMemberSelection? = stamp
        var held: StageWindowEngineHost.HeldGroup?, input = 1, events = [String](), selected: NativeSpaceWindow?
        lane.submit(stage: true) { _ in
            entered.continuation.yield(())
            var signal = release.stream.makeAsyncIterator()
            _ = await signal.next()
            events.append("previous full verification and prefix settled")
            held = f.held
        }
        var entry = entered.stream.makeAsyncIterator()
        _ = try #require(await entry.next())
        #expect(held == nil && lane.isDispatching)
        let clickedInput = input
        lane.submit(stage: true) { token in
            defer { ended.continuation.yield(()) }
            guard lane.isCurrent(token), clickedInput == input, current == stamp, let held else { return }
            events.append("new complete held read")
            var states = f.states
            if change == "badFreshLifetime" { states[0] = f.state(f.window, lifetime: UUID()) }
            guard let state = stamp.parkedState(in: f.sample(states), held: held, current: current) else { return }
            selected = state.window; events.append("exact original member selected")
        }
        #expect(events.isEmpty && selected == nil)
        switch change {
        case "revokedBinding": current = nil
        case "newInput": input += 1
        case "systemTakeover": lane.setDispatchAvailable(false)
        default: break
        }
        release.continuation.yield(())
        if change == "systemTakeover" {
            // A revoked navigation epoch drops the queued work before its body.
            lane.setDispatchAvailable(true)
            lane.submit(stage: true) { _ in ended.continuation.yield(()) }
        }
        var finish = ended.stream.makeAsyncIterator()
        _ = try #require(await finish.next())
        #expect(events.first == "previous full verification and prefix settled")
        #expect((selected == f.window) == (change == "none"))
        if change == "none" {
            #expect(events == ["previous full verification and prefix settled", "new complete held read", "exact original member selected"])
        }
        if ["revokedBinding", "newInput", "systemTakeover"].contains(change) { #expect(!events.contains("new complete held read")) }
    }
}
