import Foundation
import CoreFoundation
import Darwin

// Offline CLI only: synthetic CF objects, no WindowServer access or NSApplication.
// The function-pointer signatures remain the declarations under investigation.
typealias MainFunction = @convention(c) () -> Int32
typealias ManagedFunction = @convention(c) (Int32) -> Unmanaged<CFArray>?
typealias MembershipFunction = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

enum ProbeError: Error { case invalid(String) }
func jsonText(_ value: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
}
func cfKind(_ object: AnyObject) -> String {
    let id = CFGetTypeID(object)
    if id == CFArrayGetTypeID() { return "CFArray" }
    if id == CFDictionaryGetTypeID() { return "CFDictionary" }
    if id == CFBooleanGetTypeID() { return "CFBoolean" }
    if id == CFNumberGetTypeID() { return "CFNumber" }
    if id == CFStringGetTypeID() { return "CFString" }
    if id == CFNullGetTypeID() { return "CFNull" }
    return "other:\(id)"
}
func shape(_ object: AnyObject) -> [String: Any] {
    ["cfKind": cfKind(object), "foundationClass": String(reflecting: type(of: object))]
}
// No Double intermediate, truncating cast, or default zero. High unsigned fixture
// values are accepted only if NSNumber's exact decimal and UInt64 value agree.
func numberFacts(_ object: AnyObject) -> (String?, [String: Any]) {
    var facts = shape(object)
    guard CFGetTypeID(object) == CFNumberGetTypeID(), let number = object as? NSNumber else {
        facts["parse"] = "not_number"; return (nil, facts)
    }
    let cf = unsafeBitCast(number, to: CFNumber.self)
    let floating = CFNumberIsFloatType(cf)
    var signed: Int64 = 0
    let exactSigned = CFNumberGetValue(cf, .sInt64Type, &signed)
    facts["storageType"] = CFNumberGetType(cf).rawValue
    facts["byteSize"] = CFNumberGetByteSize(cf)
    facts["isFloat"] = floating
    facts["objCType"] = String(cString: number.objCType)
    facts["decimal"] = number.stringValue
    facts["signed64Exact"] = exactSigned
    facts["signed64"] = String(signed)
    guard !floating, let value = UInt64(number.stringValue), value == number.uint64Value else {
        facts["parse"] = "rejected_non_unsigned_integer"; return (nil, facts)
    }
    if value <= UInt64(Int64.max) && (!exactSigned || signed < 0 || UInt64(signed) != value) {
        facts["parse"] = "inexact_signed64"; return (nil, facts)
    }
    facts["parse"] = "exact_uint64"
    return (String(value), facts)
}
struct Membership: Equatable {
    let state: String
    let ids: [String]
    let errors: [String]
    let details: [String: Any]
    static func == (a: Self, b: Self) -> Bool { a.state == b.state && a.ids == b.ids && a.errors == b.errors }
    var json: [String: Any] {
        var d = details; d["state"] = state; d["spaceIDs"] = ids; d["errors"] = errors
        d["uniqueCount"] = Set(ids).count; d["count"] = ids.count
        return d
    }
}
func membership(_ raw: CFArray?) -> Membership {
    guard let raw else { return Membership(state: "null", ids: [], errors: [], details: [:]) }
    var details = shape(raw)
    guard CFGetTypeID(raw) == CFArrayGetTypeID() else {
        return Membership(state: "invalid_top_type", ids: [], errors: ["expected_CFArray"], details: details)
    }
    var ids: [String] = [], errors: [String] = [], elements: [[String: Any]] = []
    for (i, value) in (raw as NSArray).enumerated() {
        let (id, facts) = numberFacts(value as AnyObject)
        elements.append(facts)
        if let id { ids.append(id) } else { errors.append("element_\(i)_invalid") }
    }
    details["elements"] = elements
    return Membership(state: errors.isEmpty ? (ids.isEmpty ? "empty" : "values") : "invalid_elements",
                      ids: ids, errors: errors, details: details)
}
struct Inventory {
    let json: [String: Any]
    let ids: Set<String>
    let fingerprint: String
    let errors: [String]
}
func inventory(_ raw: CFArray?) -> Inventory {
    guard let raw else { return Inventory(json: ["state": "null"], ids: [], fingerprint: "null", errors: ["null"]) }
    guard CFGetTypeID(raw) == CFArrayGetTypeID() else {
        return Inventory(json: ["state": "invalid_top_type"], ids: [], fingerprint: "invalid", errors: ["not_array"])
    }
    var rows: [[String: Any]] = [], ids: Set<String> = [], errors: [String] = []
    func dictionary(_ object: AnyObject?, _ context: String) -> NSDictionary? {
        guard let object, CFGetTypeID(object) == CFDictionaryGetTypeID(), let dict = object as? NSDictionary else {
            errors.append(context + ":not_dictionary_or_missing"); return nil
        }
        return dict
    }
    func space(_ dict: NSDictionary, _ context: String) -> [String: Any] {
        var result = shape(dict)
        result["fields"] = Dictionary(uniqueKeysWithValues: dict.allKeys.compactMap { key -> (String, Any)? in
            guard let key = key as? String, let value = dict[key] else { return nil }
            return (key, shape(value as AnyObject))
        })
        if let value = dict["id64"] {
            let (id, facts) = numberFacts(value as AnyObject)
            result["id64"] = facts
            if let id { result["spaceID"] = id; ids.insert(id) } else { errors.append(context + ":invalid_id64") }
        } else { errors.append(context + ":missing_id64") }
        if let type = dict["type"] { result["type"] = numberFacts(type as AnyObject).1 }
        if let uuid = dict["uuid"] { result["uuidType"] = shape(uuid as AnyObject) }
        return result
    }
    for (index, value) in (raw as NSArray).enumerated() {
        let context = "scope_\(index)"
        guard let dict = dictionary(value as AnyObject, context) else { continue }
        var row = shape(dict)
        row["fields"] = Dictionary(uniqueKeysWithValues: dict.allKeys.compactMap { key -> (String, Any)? in
            guard let key = key as? String, let value = dict[key] else { return nil }
            return (key, shape(value as AnyObject))
        })
        if let display = dict["Display Identifier"] as? String { row["displayIdentifier"] = display }
        else { errors.append(context + ":missing_or_invalid_display_identifier") }
        if let current = dictionary(dict["Current Space"] as AnyObject?, context + ":current") {
            row["current"] = space(current, context + ":current")
        }
        if let value = dict["Spaces"], CFGetTypeID(value as AnyObject) == CFArrayGetTypeID(), let list = value as? NSArray {
            row["spacesArrayType"] = shape(list)
            var spaces: [[String: Any]] = []
            for (i, entry) in list.enumerated() {
                if let d = dictionary(entry as AnyObject, context + ":space_\(i)") { spaces.append(space(d, context + ":space_\(i)")) }
            }
            row["spaces"] = spaces
        } else { errors.append(context + ":missing_or_invalid_spaces") }
        rows.append(row)
    }
    var result = shape(raw)
    result["state"] = errors.isEmpty ? ((raw as NSArray).count == 0 ? "empty" : "values") : "invalid_fields"
    result["scopes"] = rows; result["errors"] = errors
    return Inventory(json: result, ids: ids, fingerprint: (try? jsonText(result)) ?? "invalid_json", errors: errors)
}
func cMembership(_ array: CFArray) -> Membership {
    let pointer = Unmanaged.passUnretained(array).toOpaque()
    guard let raw = NPCopyMembership(pointer) else { return membership(nil) }
    defer { NPReleaseOutput(raw) }
    return membership(Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue())
}
func cInventory() -> Inventory {
    guard let raw = NPCopyManaged() else { return inventory(nil) }
    defer { NPReleaseOutput(raw) }
    return inventory(Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue())
}
func withExplicit<T>(_ ids: [UInt32], _ body: (CFArray) throws -> T) throws -> T {
    guard let raw = ids.withUnsafeBufferPointer({ NPCreateSInt32Windows($0.baseAddress, $0.count) }) else {
        throw ProbeError.invalid("CFNumber/CFArray construction failed")
    }
    defer { NPReleaseInput(raw) }
    return try body(Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue())
}
struct Window {
    let id: UInt32
    let original: NSNumber
    let label: String
    let onscreen: Bool
}
func windowSample() -> ([Window], Set<UInt32>) {
    // Int64 NSNumber inputs exercise the baseline [NSNumber] as CFArray bridge.
    // These are invented IDs with explicit synthetic membership, not real windows.
    let ids: [UInt32] = [101, 202, 303, 404]
    return (ids.enumerated().map { Window(id: $0.element, original: NSNumber(value: Int64($0.element)),
                                         label: "F\($0.offset + 1)", onscreen: false) }, Set(ids))
}
func countersJSON() -> [String: Any] {
    let c = NPGetCounters()
    return ["mainCalls": c.main_calls, "managedCalls": c.managed_calls, "membershipCalls": c.membership_calls,
            "managedNonnull": c.managed_nonnull, "membershipNonnull": c.membership_nonnull,
            "outputReleases": c.output_releases, "inputCreates": c.input_creates, "inputReleases": c.input_releases,
            "numberCreates": c.number_creates, "numberReleases": c.number_releases, "rejectedInputs": c.rejected_inputs,
            "balanced": c.managed_nonnull + c.membership_nonnull == c.output_releases && c.input_creates == c.input_releases && c.number_creates == c.number_releases]
}
func memoryJSON(_ iteration: Int) -> [String: Any] {
    let m = NPGetMemory()
    return ["iteration": iteration, "residentBytes": m.resident_bytes, "mallocBytes": m.malloc_bytes,
            "mallocBlocks": m.malloc_blocks, "status": m.memory_status]
}
func allocatorJSON() -> [String: Any] {
    let a = NPGetFixtureAllocatorCounters()
    return ["allocations": a.allocations, "deallocations": a.deallocations, "reallocations": a.reallocations,
            "outstandingBlocks": a.outstanding_blocks, "outstandingBytes": a.outstanding_bytes,
            "balanced": a.allocations == a.deallocations && a.outstanding_blocks == 0 && a.outstanding_bytes == 0,
            "scope": "only CF objects created with this fixture allocator; excludes Swift runtime and SkyLight"]
}
func fixtures() -> [[String: Any]] {
    let values: [(String, AnyObject, String?)] = [
        ("zero", NSNumber(value: UInt64(0)), "0"),
        ("above_uint32", NSNumber(value: UInt64(4_294_967_313)), "4294967313"),
        ("above_double_exact_range", NSNumber(value: UInt64(9_007_199_254_740_993)), "9007199254740993"),
        ("int64_max", NSNumber(value: Int64.max), String(Int64.max)),
        ("uint64_max", NSNumber(value: UInt64.max), String(UInt64.max)),
        ("negative", NSNumber(value: Int64(-1)), nil),
        ("fraction", NSNumber(value: 1.5), nil),
        ("boolean", NSNumber(value: true), nil),
        ("numeric_string", "123" as NSString, nil),
        ("null", NSNull(), nil)
    ]
    var result = values.map { name, object, expected -> [String: Any] in
        let (actual, facts) = numberFacts(object)
        return ["name": name, "facts": facts, "expected": expected as Any? ?? NSNull(), "actual": actual as Any? ?? NSNull(), "passed": actual == expected]
    }
    let empty: CFArray = [] as CFArray
    let wrong: CFArray = ["123" as NSString] as CFArray
    let wrongTop = ["fixture": 1] as NSDictionary
    let wrongTopArray = Unmanaged<CFArray>.fromOpaque(Unmanaged.passUnretained(wrongTop).toOpaque()).takeUnretainedValue()
    result.append(["name": "null_vs_empty", "passed": membership(nil).state == "null" && membership(empty).state == "empty"])
    result.append(["name": "wrong_top_type", "passed": membership(wrongTopArray).state == "invalid_top_type"])
    result.append(["name": "bad_membership_element", "passed": membership(wrong).state == "invalid_elements"])
    let missing: CFArray = [["Display Identifier": "fixture", "Spaces": [], "Current Space": [:]] as NSDictionary] as CFArray
    let invalidID: CFArray = [["Display Identifier": "fixture", "Spaces": [["id64": "1"]], "Current Space": ["id64": true]] as NSDictionary] as CFArray
    result.append(["name": "missing_id64", "passed": !inventory(missing).errors.isEmpty, "errors": inventory(missing).errors])
    result.append(["name": "wrong_id64_types", "passed": !inventory(invalidID).errors.isEmpty, "errors": inventory(invalidID).errors])
    return result
}
func guardFixtures() -> [[String: Any]] {
    let tests: [(String, AnyObject?, Int32)] = [
        ("null_input", nil, 2), ("string_input", "bad" as NSString, 2),
        ("string_element", ["123"] as NSArray, 4), ("boolean_element", [true] as NSArray, 4),
        ("fraction_element", [1.5] as NSArray, 4),
        ("out_of_range", [NSNumber(value: UInt64.max)] as NSArray, 5),
        ("above_uint32", [NSNumber(value: UInt64(UInt32.max) + 1)] as NSArray, 5),
        ("below_sint32", [NSNumber(value: Int64(Int32.min) - 1)] as NSArray, 5),
        ("too_many_ids", Array(repeating: NSNumber(value: 1), count: 65) as NSArray, 6)
    ]
    return tests.map { name, object, expected in
        let before = NPGetCounters().membership_calls
        let pointer = object.map { UnsafeRawPointer(Unmanaged.passUnretained($0).toOpaque()) }
        let result = NPCopyMembership(pointer)
        let code = NPLastError()
        if let result { NPReleaseOutput(result) }
        return ["name": name, "error": code, "expected": expected,
                "fixtureCallCountDelta": NPGetCounters().membership_calls - before,
                "passed": code == expected && result == nil && NPGetCounters().membership_calls == before]
    }
}
func run(iterations: Int, matrixEnabled: Bool) throws -> [String: Any] {
    guard let mainAddress = NPFunctionAddress(0), let managedAddress = NPFunctionAddress(1), let memberAddress = NPFunctionAddress(2) else {
        throw ProbeError.invalid("missing allowlisted function")
    }
    let swiftMain = unsafeBitCast(mainAddress, to: MainFunction.self)
    let swiftManaged = unsafeBitCast(managedAddress, to: ManagedFunction.self)
    let swiftMember = unsafeBitCast(memberAddress, to: MembershipFunction.self)
    let connection = NPMainConnection()
    var swiftMemberNonnull = 0, swiftManagedNonnull = 0, swiftRetainedConsumes = 0
    func swiftMembership(_ input: CFArray) throws -> Membership {
        guard NPValidateInput(Unmanaged.passUnretained(input).toOpaque()) == 0 else { throw ProbeError.invalid("Swift input rejected") }
        guard let raw = swiftMember(connection, 0x7, input) else { return membership(nil) }
        swiftMemberNonnull += 1; swiftRetainedConsumes += 1
        // Same retained-return handling and [NSNumber] bridge as the baseline.
        return membership(raw.takeRetainedValue())
    }
    func swiftInventory() -> Inventory {
        guard let raw = swiftManaged(connection) else { return inventory(nil) }
        swiftManagedNonnull += 1; swiftRetainedConsumes += 1
        return inventory(raw.takeRetainedValue())
    }
    let connectionSamples = (0..<8).map { _ in [NPMainConnection(), swiftMain()] }
    let before = autoreleasepool { cInventory() }
    let swiftBefore = autoreleasepool { swiftInventory() }
    guard before.errors.isEmpty, swiftBefore.errors.isEmpty,
          before.json["state"] as? String == "values", swiftBefore.json["state"] as? String == "values" else {
        throw ProbeError.invalid("managed_prerequisite_failed_before_membership:\(before.json["state"] ?? "unknown")")
    }
    let (windows, allIDsBefore) = windowSample()
    guard windows.count >= 2 else { throw ProbeError.invalid("fewer than two fixture windows") }
    let original = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.original) })
    func bridge(_ ids: [UInt32]) -> CFArray { ids.map { original[$0] ?? NSNumber(value: $0) } as CFArray }
    var discovery: [UInt32: Membership] = [:]
    for window in windows { discovery[window.id] = try autoreleasepool { try withExplicit([window.id]) { cMembership($0) } } }
    guard discovery[101]?.state == "values" else {
        throw ProbeError.invalid("fixture_membership_prerequisite_failed:\(discovery[101]?.state ?? "missing")")
    }
    let first = windows.first { discovery[$0.id]?.state == "values" } ?? windows[0]
    let second = windows.first { $0.id != first.id && discovery[$0.id]?.state == "values" && Set(discovery[$0.id]!.ids) != Set(discovery[first.id]!.ids) }
        ?? windows.first { $0.id != first.id }!
    var cases: [(String, [UInt32])] = [("empty", [])]
    cases += windows.map { ("single_" + $0.label, [$0.id]) }
    cases += [("pair", [first.id, second.id]), ("pair_reversed", [second.id, first.id]),
              ("duplicate_single", [first.id, first.id]), ("duplicate_pair", [first.id, second.id, first.id]),
              ("all_sampled", windows.map(\.id)), ("all_reversed", windows.reversed().map(\.id))]
    let invalids: [(String, UInt32)] = [("invalid_zero", 0), ("invalid_uint32_max", UInt32.max), ("invalid_sign_bit", 0x80000000)]
    for (name, id) in invalids where !allIDsBefore.contains(id) { cases.append((name, [id])) }
    if !allIDsBefore.contains(UInt32.max) { cases.append(("known_plus_invalid", [first.id, UInt32.max])) }
    var matrix: [[String: Any]] = [], mismatches = 0, invalidResults = 0
    if matrixEnabled {
        for round in 1...3 {
                for (name, ids) in cases {
                    try autoreleasepool {
                        try withExplicit(ids) { explicit in
                            let bridged = bridge(ids)
                            let a = cMembership(explicit)
                            let b = cMembership(bridged)
                            let c = try swiftMembership(explicit)
                            let d = try swiftMembership(bridged)
                            let equal = a == b && b == c && c == d
                            if !equal { mismatches += 1 }
                            invalidResults += [a, b, c, d].filter { !$0.errors.isEmpty }.count
                            matrix.append(["round": round, "selector": 0x7, "case": name,
                                           "windowIDs": ids.map(String.init), "equalAcrossFourPaths": equal,
                                           "c_explicit": a.json, "c_bridge": b.json, "swift_explicit": c.json, "swift_bridge": d.json])
                        }
                    }
                }
        }
    }
    let inputTypes: [[String: Any]] = try windows.map { window in
        try withExplicit([window.id]) { explicit in
            ["label": window.label, "windowID": String(window.id), "onscreenAtSelection": window.onscreen,
             "originalNSNumber": numberFacts(window.original).1,
             "explicitSInt32": numberFacts((explicit as NSArray)[0] as AnyObject).1,
             "initialMembership": discovery[window.id]!.json]
        }
    }
    var memory: [[String: Any]] = [], repeatMismatches = 0, repeatInvalid = 0, inventoryChanges = 0, connectionChanges = 0
    let repeatReference = discovery[first.id]!
    let started = Date()
    // Retain no per-call CF objects across a pool drain. Warm up before measuring.
    for i in 0..<(iterations + 100) {
        try autoreleasepool {
            try withExplicit([first.id]) { explicit in
                let bridged = bridge([first.id])
                let results = [cMembership(explicit), cMembership(bridged), try swiftMembership(explicit), try swiftMembership(bridged)]
                if i >= 100 {
                    repeatMismatches += results.filter { $0 != repeatReference }.count
                    repeatInvalid += results.filter { !$0.errors.isEmpty }.count
                }
                let managed = cInventory()
                let swift = swiftInventory()
                if i >= 100 && (managed.fingerprint != before.fingerprint || swift.fingerprint != before.fingerprint) { inventoryChanges += 1 }
                if NPMainConnection() != connection || swiftMain() != connection { connectionChanges += 1 }
            }
        }
        if i == 99 || (i >= 100 && (i - 99) % 100 == 0) || i == iterations + 99 { memory.append(memoryJSON(max(0, i - 99))) }
    }
    let after = autoreleasepool { cInventory() }
    let (_, allIDsAfter) = windowSample()
    let parserFixtures = fixtures(), guards = guardFixtures()
    return [
        "probe": "nearpane-p1-abi", "schemaVersion": 2, "mode": "offline_synthetic_CF_fixtures",
        "interpretation": "Fixture behavior is defined by this test, not evidence of SkyLight semantics.",
        "environment": ["osVersion": ProcessInfo.processInfo.operatingSystemVersionString, "architecture": "arm64", "thread": "main_only"],
        "abi": ["cIntBytes": NPIntBytes(), "swiftInt32Bytes": MemoryLayout<Int32>.size,
                "cgWindowIDBytes": NPWindowIDBytes(), "swiftUInt32Bytes": MemoryLayout<UInt32>.size,
                "uint64Bytes": MemoryLayout<UInt64>.size, "pointerBytes": MemoryLayout<UnsafeRawPointer>.size,
                "cfIndexBytes": MemoryLayout<CFIndex>.size, "staticTypeAssertionsCompiled": true],
        "connection": ["raw": connection, "samples": connectionSamples, "allEqual": connectionSamples.flatMap { $0 }.allSatisfy { $0 == connection }, "stressChanges": connectionChanges],
        "windows": inputTypes, "selectedWindowsStillPresent": windows.allSatisfy { allIDsAfter.contains($0.id) },
        "invalidIDsAbsentBeforeAndAfter": invalids.map { ["name": $0.0, "id": String($0.1), "absent": !allIDsBefore.contains($0.1) && !allIDsAfter.contains($0.1)] },
        "pairWindowIDs": [String(first.id), String(second.id)],
        "inventoryBefore": before.json, "inventorySwift": swiftBefore.json, "inventoryAfter": after.json,
        "inventoryCAndSwiftEqual": before.fingerprint == swiftBefore.fingerprint,
        "inventoryBeforeAndAfterEqual": before.fingerprint == after.fingerprint,
        "matrix": matrix, "matrixMismatchCount": mismatches, "matrixInvalidResultCount": invalidResults,
        "parserFixtures": parserFixtures, "guardFixtures": guards,
        "repeated": ["measuredIterations": iterations, "warmupIterations": 100, "membershipCallsPerIteration": 4,
                     "managedCallsPerIteration": 2, "mismatchesAgainstInitial": repeatMismatches,
                     "invalidResults": repeatInvalid, "inventoryChanges": inventoryChanges,
                     "durationSeconds": Date().timeIntervalSince(started), "memory": memory],
        "cOwnership": countersJSON(),
        "swiftOwnership": ["membershipNonnull": swiftMemberNonnull, "managedNonnull": swiftManagedNonnull,
                           "takeRetainedValueCalls": swiftRetainedConsumes,
                           "allNonnullConsumedOnce": swiftRetainedConsumes == swiftMemberNonnull + swiftManagedNonnull],
        "safety": ["capturedPixels": false, "changedFocus": false, "switchedSpaces": false, "requestedPermissions": false,
                   "changedSettings": false, "createdWindows": false, "liveBackendCompiled": NPLiveBackendCompiled() != 0,
                   "fixtureBackend": NPIsFixtureBackend() != 0, "windowServerAccess": false]
    ]
}

func main() -> Int32 {
    let args = Array(CommandLine.arguments.dropFirst())
    var iterations = 1000, matrix = true, fault: Int32 = 0
    var index = 0
    while index < args.count {
        switch args[index] {
        case "--iterations":
            index += 1
            guard index < args.count, let n = Int(args[index]), (1...2000).contains(n) else { return 64 }
            iterations = n
        case "--stress-only": matrix = false
        case "--fault":
            index += 1
            guard index < args.count else { return 64 }
            if args[index] == "missing-library" { fault = 1 }
            else if args[index] == "missing-symbol" { fault = 2 }
            else if args[index] == "managed-null" { fault = 3 }
            else if args[index] == "managed-malformed" { fault = 4 }
            else if args[index] == "membership-null" { fault = 5 }
            else if args[index] == "membership-wrong-type" { fault = 6 }
            else { return 64 }
        default: return 64
        }
        index += 1
    }
    var error = [CChar](repeating: 0, count: 1024)
    // No command-line option enables the live backend, even in an opt-in C build.
    guard NPLiveBackendCompiled() == 0 else { return 64 }
    let initialized = NPInitializeFixtures(fault, &error, error.count)
    if initialized != 0 {
        let expected = (fault == 1 && initialized == 2) || (fault == 2 && initialized == 3)
        let value: [String: Any] = ["mode": "offline_synthetic_CF_fixtures", "state": "initialization_error", "code": initialized,
                                  "message": String(cString: error), "expectedFault": expected,
                                  "cOwnership": countersJSON(), "shutdown": NPShutdown()]
        if let text = try? jsonText(value) { print(text) }
        return expected ? 0 : 2
    }
    do {
        var result = try autoreleasepool { try run(iterations: iterations, matrixEnabled: matrix) }
        // All direct Swift function pointers and all returned objects have left scope.
        let closed = NPShutdown()
        let noAddress = (0...2).allSatisfy { NPFunctionAddress(Int32($0)) == nil }
        let afterClose = NPCopyManaged()
        result["lifecycle"] = ["shutdownStatus": closed, "addressesCleared": noAddress,
                               "callAfterCloseRejected": afterClose == nil && NPLastError() == 1]
        result["fixtureAllocatorAfterShutdown"] = allocatorJSON()
        let fixturePass = ["parserFixtures", "guardFixtures"].allSatisfy { key in
            guard let rows = result[key] as? [[String: Any]], !rows.isEmpty else { return false }
            return rows.allSatisfy { ($0["passed"] as? Bool) == true }
        }
        let ownership = result["cOwnership"] as? [String: Any]
        let repeated = result["repeated"] as? [String: Any]
        let validated = fixturePass && closed == 0 && noAddress && afterClose == nil &&
            allocatorJSON()["balanced"] as? Bool == true &&
            ownership?["balanced"] as? Bool == true && result["matrixInvalidResultCount"] as? Int == 0 &&
            result["matrixMismatchCount"] as? Int == 0 && repeated?["invalidResults"] as? Int == 0
        result["validationPassed"] = validated
        print(try jsonText(result))
        return validated ? 0 : 4
    } catch {
        let closed = NPShutdown()
        let value: [String: Any] = ["mode": "offline_synthetic_CF_fixtures", "state": "helper_error", "error": String(describing: error),
                                  "shutdown": closed, "cOwnership": countersJSON(), "fixtureAllocatorAfterShutdown": allocatorJSON()]
        if let text = try? jsonText(value) { print(text) }
        return 2
    }
}
exit(main())
