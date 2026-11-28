// Compile alongside FinderTrial.swift with -D FINDER_TRIAL_TESTS. No AppKit session or system input.
import Foundation

@main enum FinderTrialTests {
    static func main() throws {
        func plan(_ a: String?, _ b: String?) -> Plan {
            Plan(directory: "", repository: "", display: "side", python: "", helpersSHA256: "",
                 witnessSHA256: "", scripts: [:], secondarySource: a, existingTarget: b, displayFingerprints: [])
        }
        func origin(_ order: [String], active: String = "10", display: String = "side") -> Origin {
            Origin(scopes: [.init(displayID: display, records: order.map { .init(id: $0, isCurrent: $0 == active) })],
                   ordinaryRecordsByDisplay: [display: order])
        }
        func receipt(_ a: String, _ b: String, _ created: Bool, trips: Int = 3) -> Completion {
            Completion(roundTrips: trips, source: a, target: b, createdAndRemoved: created)
        }
        let single = plan(nil, nil), create = plan("10", nil), existing = plan("10", "11")
        try checked(try single.route() == ["--check-overview-first", "--current-display", "--provision-current",
                                            "--source", "rightmost-current"], "single display route")
        try checked(try create.route() == ["--check-overview-first", "--allow-primary-overview", "--source", "10"],
                    "create route")
        try checked(try existing.route() == ["--source", "10", "--existing-target", "11"], "existing route")
        for malformed in [plan(nil, "11"), plan("10", "10"), plan("10", "0"), plan("10", "011"), plan("xx", nil)] {
            try checked((try? malformed.route()) == nil, "invalid plan accepted")
        }
        try checked(create.accepts(receipt("10", "11", true), origin: origin(["10"])), "created pair")
        try checked(single.accepts(receipt("10", "11", true), origin: origin(["9", "10"])), "single display")
        let pair = origin(["10", "11"])
        for order in [["11", "10"], ["10", "11"]] {
            try checked(existing.accepts(receipt("10", "11", false), origin: origin(order)), "existing pair")
        }
        for invalid in [receipt("10", "12", false), receipt("12", "11", false), receipt("10", "11", true),
                        receipt("10", "11", false, trips: 2)] {
            try checked(!existing.accepts(invalid, origin: pair), "unbound existing completion")
        }
        for invalid in [origin(["10", "11"], display: "primary"), origin(["10", "12", "11"]),
                        origin(["10", "11"], active: "11")] {
            try checked(!existing.accepts(receipt("10", "11", false), origin: invalid), "wrong origin")
        }
        try checked(!create.accepts(receipt("10", "11", true), origin: pair), "pre-existing B reported removed")
        try checked(!create.accepts(receipt("10", "11", false), origin: origin(["10"])), "missing cleanup")
        print("21 Finder route and completion cases passed")
    }
}
