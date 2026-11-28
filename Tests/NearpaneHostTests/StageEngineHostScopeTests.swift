import Foundation
import Testing
@testable import NearpaneHost

struct StageEngineHostScopeTests {
    private typealias Probe = StageEngineHostScope
    private let display = UUID(uuidString: "2D597320-F02D-4751-812E-5BC113245A11")!
    private let space = "0F4D7078-D098-403A-A541-1B0690BA78B7"

    private func row(_ n: Int = 42, type: Int = 0) -> [String: Any] {
        ["id64": n, "ManagedSpaceID": n, "uuid": space, "type": type]
    }
    private func inventory(_ current: [String: Any], _ roster: [[String: Any]], token: String? = nil,
                           single: Bool = true) -> Probe.Inventory {
        Probe.Inventory(rows: [["Display Identifier": token ?? display.uuidString, "Current Space": current, "Spaces": roster]],
                        display: display, singleMain: single)
    }
    private func stamp(seq: UInt64 = 0, endSeq: UInt64 = 0, start: UInt64 = 10, login: UInt32? = 7,
                       pid: Int32 = 55, screens: [String] = ["d"], connection: Int32 = 9) -> Probe.Continuity {
        .init(pid: pid, birth: 8, login: login, screens: screens, completeScreen: true, connection: connection,
              seqStart: seq, seqEnd: endSeq, timeStart: start, timeEnd: start + 1)
    }

    @Test func testIndependentCurrentAndUniqueDisplayBindOrdinaryIdentity() {
        let source = row(), result = inventory(source, [row(10), source]).evaluate(direct: 42, directAfter: 42)
        #expect(result.0.status == "PASS")
        #expect(result.1 == Probe.Identity(display: display, space: UUID(uuidString: space)!, number: 42))
        #expect(inventory(source, [source], token: "Main").evaluate(direct: 42, directAfter: 42).0.status == "PASS")
        #expect(inventory(source, [source], token: "Main", single: false).evaluate(direct: 42, directAfter: 42).0.status == "UNKNOWN")
        #expect(inventory(source, [source], token: "unrelated token").evaluate(direct: 42, directAfter: 42).0.status == "UNKNOWN")
    }

    @Test func testFullscreenAndMissingRequiredFieldsPreserveActualCategoryAndNeverPass() {
        let full = row(type: 4)
        let desktop = inventory(full, [full])
        #expect(desktop.current.json["type"] as? UInt64 == 4)
        #expect(desktop.matches.first?.json["type"] as? UInt64 == 4)
        #expect(desktop.evaluate(direct: 42, directAfter: 42).0 == .init(status: "BLOCKED", reason: "fullscreenType4"))
        for key in ["uuid", "type"] {
            var omitted = row()
            omitted[key] = nil
            for pair in [(omitted, row()), (row(), omitted)] {
                #expect(inventory(pair.0,[pair.1]).evaluate(direct: 42, directAfter: 42).0.status == "UNKNOWN")
            }
        }
        var zero = row()
        zero["uuid"] = "00000000-0000-0000-0000-000000000000"
        #expect(inventory(zero, [row()]).evaluate(direct: 42, directAfter: 42).1 == nil)
    }

    @Test func testConflictingNumericAliasesTypesAndDirectReadCannotBecomeOrdinary() {
        let source = row()
        var malformed = row()
        malformed["ManagedSpaceID"] = 18
        for raw in [malformed, ["id64":true,"uuid":space,"type":0], ["id64":0,"uuid":space,"type":0],
                    ["id64":42,"type":NSNull(),"uuid":space], ["id64":42,"type":0,"uuid":false]] {
            #expect(inventory(raw, [source]).evaluate(direct: 42, directAfter: 42).1 == nil)
        }
        for roster in [[source,source], [malformed], [row(10)], [row(type: 2)]] {
            #expect(inventory(source,roster).evaluate(direct: 42, directAfter: 42).1 == nil)
        }
        for d in [(nil,UInt64(42) as UInt64?), (42,nil), (42,99)] as [(UInt64?,UInt64?)] {
            #expect(inventory(source,[source]).evaluate(direct:d.0,directAfter:d.1).1 == nil)
        }
    }

    @Test func testBothReadClocksProcessSessionTopologyAndWorkspaceGenerationMustAgree() {
        let a = stamp(), b = stamp(start: 30)
        let (v, id) = inventory(row(), [row()]).evaluate(direct: 42, directAfter: 42)
        #expect(Probe.pair(a,b,v,v,id,id).status == "PASS")
        for altered in [stamp(start:10),stamp(endSeq:1,start:30),stamp(seq:1,endSeq:1,start:30),
                        stamp(start:30,login:8),stamp(start:30,login:nil),stamp(start:30,pid:65),
                        stamp(start:30,screens:["other"]),stamp(start:30,connection:99)] {
            #expect(Probe.pair(a,altered,v,v,id,id).status == "UNKNOWN")
        }
        let other = Probe.Identity(display:display,space:UUID(uuidString:"B5F96CAF-3B8D-4D0A-B177-6FBBEC533442")!,number:42)
        #expect(Probe.pair(a,b,v,v,id,other).status == "UNKNOWN")
    }

    @Test func directionalReadbacksKeepIndependentFailuresAndDoNotQualifyFullscreen() {
        let full = inventory(row(type:4),[row(type:4)]).evaluate(direct:42,directAfter:42)
        #expect(full.0.status == "BLOCKED")
        let first = Probe.MemberRead(registered:true,bound:true,active:42,reverse:[42],forward:1,local:nil)
        let last = Probe.MemberRead(registered:true,bound:true,active:42,reverse:nil,forward:1,local:nil)
        let checks = Probe.memberPair(first,last,current:full.1?.number,registered:true)
        #expect(checks.forward.status == "PASS")
        #expect(checks.reverse.status == "UNKNOWN")
        #expect(checks.combined.status == "UNKNOWN")
        #expect(Probe.memberPair(first,first,current:nil,registered:true).forward.status == "UNKNOWN")
        #expect(Probe.memberPair(first,first,current:nil,registered:false).reverse.status == "NOT_RUN")
        let rebound = Probe.MemberRead(registered:true,bound:false,active:42,reverse:[42],forward:1,local:true)
        #expect(Probe.memberPair(rebound,rebound,current:42,registered:true).forward.status == "UNKNOWN")
        #expect(Probe.memberPair(rebound,rebound,current:42,registered:true).reverse.status == "UNKNOWN")
    }

    @Test func testSignedWindowNeedsBothRealDirectionsAndNoAppKitContradiction() {
        func verdict(_ r: [UInt64]?, _ f: Int32?, local: Bool? = nil, signed: Bool = true, registered: Bool = true) -> String {
            Probe.MemberRead(registered:registered,bound:signed,active:42,reverse:r,forward:f,local:local).verdict.status
        }
        #expect(verdict([42],1) == "PASS")
        #expect(verdict([42],1,local:true) == "PASS")
        #expect(verdict([42],1,local:false) == "UNKNOWN")
        #expect(verdict([42],0) == "UNKNOWN")
        #expect(verdict([9],1) == "UNKNOWN")
        #expect(verdict([42,42],1) == "UNKNOWN")
        #expect(verdict([42],2) == "UNKNOWN")
        #expect(verdict([9],0) == "FAIL")
        #expect(verdict([42,9],1) == "FAIL")
        #expect(verdict(nil,0) == "UNKNOWN")
        #expect(verdict([42],nil) == "UNKNOWN")
        #expect(verdict([42],1,signed:false) == "UNKNOWN")
        #expect(verdict(nil,nil,signed:false,registered:false) == "NOT_RUN")
    }
}
