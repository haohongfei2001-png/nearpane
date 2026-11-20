import ApplicationServices
import NearpaneCore
@testable import NearpaneSpaceAction
import Testing

@MainActor struct SidebarWindowWitnessTests {
    let display = UUID(), space = UUID()
    func location(number: UInt32 = 15, pid: Int32 = 198, birth: UInt64 = 88,
                  screen: UUID? = nil, uuid: UUID? = nil) -> NativeSidebarWindowLocation {
        .init(window: .init(pid: pid, birth: birth, number: number), display: screen ?? display,
              space: "4975", spaceUUID: uuid ?? space)
    }

    @Test func offSpaceListOmissionCanOnlyVerifyAnAlreadyRetainedLiveEntity() throws {
        // Opaque references only. No calls reach AX, WindowServer or an application.
        let original = AXUIElementCreateApplication(1234), replacement = AXUIElementCreateApplication(1235)
        let history = SidebarWindowWitnesses(), scope = location()
        let current = NativeSidebarWindowProbe(scope, current: true, original: nil)
        let background = NativeSidebarWindowProbe(scope, current: false, original: nil)
        var rows = [original], responsive = true
        let inspect: SidebarWindowWitnesses.Check = { _, active, saved in
            guard responsive else { return nil }
            return SidebarWindowRead.original(in: rows, current: active, retained: saved)
        }
        #expect(history.sample(background, session: 2, now: 1, check: inspect) == nil)
        let token = try #require(history.sample(current, session: 2, now: 2, check: inspect))
        rows = []
        let hidden = NativeSidebarWindowProbe(scope, current: false, original: token)
        #expect(history.sample(hidden, session: 2, now: 3, check: inspect) == token)
        rows = [replacement]
        #expect(history.sample(hidden, session: 2, now: 4, check: inspect) == nil)
        rows = [original]
        #expect(history.sample(hidden, session: 2, now: 5, check: inspect) == nil)
        let new = try #require(history.sample(current, session: 2, now: 6, check: inspect))
        #expect(new != token)
        rows = []
        responsive = false
        #expect(history.sample(.init(scope, current: false, original: new), session: 2, now: 7, check: inspect) == nil)
        #expect(SidebarWindowRead.original(in: [], current: true, retained: original) == nil)
        #expect(SidebarWindowRead.original(in: [original,replacement], current: false, retained: original) == nil)
    }

    @Test func aTransientReadWithholdsTheOriginalUntilPositiveProofAndCannotRefreshItsExpiry() throws {
        let held = SidebarWindowWitnesses(), scope = location(), element = AXUIElementCreateApplication(401)
        let home = NativeSidebarWindowProbe(scope, current: true, original: nil)
        let original = try #require(held.sample(home, session: 1, now: 20, check: { _,_,_ in element }))
        for (offset, active) in [false,true].enumerated() {
            let t = Double(21 + 2 * offset)
            let probe = NativeSidebarWindowProbe(scope, current: active, original: original)
            #expect(held.sample(probe, session: 1, now: t, check: { _,_,_ in nil }, contradicted: { false }) == nil)
            #expect(held.sample(probe, session: 1, now: t + 1, check: { _,_,saved in saved }, contradicted: { false }) == original)
        }
        let background = NativeSidebarWindowProbe(scope, current: false, original: original)
        #expect(held.sample(background, session: 1, now: 35.9, check: { _,_,_ in nil }, contradicted: { false }) == nil)
        #expect(held.sample(background, session: 1, now: 36.01, check: { _,_,saved in saved }) == nil)
        let replacement = try #require(held.sample(home, session: 1, now: 37, check: { _,_,_ in element }))
        let fresh = NativeSidebarWindowProbe(scope, current: false, original: replacement)
        #expect(held.sample(fresh, session: 1, now: 38, check: { _,_,_ in nil }, contradicted: { true }) == nil)
        #expect(held.sample(fresh, session: 1, now: 39, check: { _,_,saved in saved }) == nil)
    }

    @Test func originalPropertiesRequirePositiveSupportAndReportAllFieldsAtOnce() throws {
        var err = AXError.attributeUnsupported
        let unsupported = try #require(AXValueCreate(.axError,&err))
        var facts = [String: String]()
        func read(_ fields: [Any]) -> SidebarWindowRead.DirectEvidence {
            SidebarWindowRead.properties(status: .success, fields: fields) { facts[$0] = $1 }
        }
        #expect(read([kAXWindowRole,kAXStandardWindowSubrole,false,false,false]) == .verified)
        #expect(read([kAXWindowRole,kAXStandardWindowSubrole,unsupported,false,false]) == .unavailable("original-ax-modal-unreadable"))
        #expect(facts["original.modal"] == "ax-error-" + String(err.rawValue))
        #expect(facts["original.minimized"] == "false" && facts["original.fullscreen"] == "false")
        #expect(read([kAXWindowRole,kAXStandardWindowSubrole,NSNumber(value: 0),false,false]) == .unavailable("original-ax-modal-unreadable"))
        #expect(read([kAXWindowRole,kAXStandardWindowSubrole,unsupported,true,false]) == .invalid("original-ax-minimized-contradiction"))
        #expect(read([kAXWindowRole,kAXStandardWindowSubrole,true,false,false]) == .invalid("original-ax-modal-contradiction"))
        #expect(SidebarWindowRead.properties(status: .invalidUIElement, fields: nil, fact: { _,_ in }) == .invalid("original-ax-object-invalid"))
    }

    @Test func samplesThatStraddleAnActualSpaceChangeCannotRevokeOrPublishAWindow() throws {
        func view(_ current: String) -> ActionInventory {
            let screen = ActionInventory.Display(number: 1, bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
                                                  current: current, spaces: [])
            return .init(displays: [display: screen], session: 1)
        }
        let home = view("4975"), other = view("4976")
        let history = SidebarWindowWitnesses(), scope = location(), entity = AXUIElementCreateApplication(1234)
        let start = NativeSidebarWindowProbe(scope, current: true, original: nil)
        let registered = try history.observe([start], inventory: home, permitted: { true }, after: { home }, check: { _,_,_ in entity })
        let token = try #require(registered[0])
        let source = NativeSidebarWindowProbe(scope, current: true, original: token)
        let away = NativeSidebarWindowProbe(scope, current: false, original: token)
        #expect(throws: ActionFailure.self) {
            try history.observe([source], inventory: other, permitted: { true }, after: { other }, check: { _,_,_ in nil })
        }
        #expect(throws: ActionFailure.self) {
            try history.observe([source], inventory: home, permitted: { true }, after: { other }, check: { _,_,_ in nil })
        }
        var withheld = [Int]()
        #expect(try history.observe([away], inventory: other, permitted: { true }, after: { other },
                                    check: { _,_,_ in nil }, withheld: { withheld.append($0) }) == [nil])
        #expect(withheld == [0])
        #expect(try history.observe([away], inventory: other, permitted: { true }, after: { other },
                                    check: { _,_,saved in saved }) == [token])
        #expect(throws: ActionFailure.self) {
            try history.observe([away], inventory: other, permitted: { false }, after: { other }, check: { _,_,_ in entity })
        }
        #expect(try history.observe([away], inventory: other, permitted: { true }, after: { other },
                                    check: { _,_,_ in entity }) == [nil])
    }

    @Test func restartIDReuseScopePermissionSessionAndExpiryEachInvalidateTheOldSelection() throws {
        let history = SidebarWindowWitnesses(), scope = location()
        let entity = AXUIElementCreateApplication(1234)
        let live: SidebarWindowWitnesses.Check = { _,_,_ in entity }
        for changed in [location(number: 16), location(pid: 199), location(birth: 89),
                        location(screen: UUID()), location(uuid: UUID())] {
            let token = try #require(history.sample(.init(scope,current:true,original:nil), session: 1, now: 0, check: live))
            #expect(history.sample(.init(changed,current:false,original:token), session: 1, now: 1, check: live) == nil)
            #expect(history.sample(.init(scope,current:false,original:token), session: 1, now: 2, check: live) == nil)
        }
        for (session, time, permit) in [(2,2.0,true),(1,12.01,true),(1,2.0,false)] {
            let token = try #require(history.sample(.init(scope,current:true,original:nil), session: 1, now: 0, check: live))
            #expect(history.sample(.init(scope,current:false,original:token), session: session, now: time,
                                   check: { _,_,_ in permit ? entity : nil }) == nil)
        }
    }
}
