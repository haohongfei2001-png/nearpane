import Foundation

struct FiveOwner: Codable, Equatable {
    let slot: Int, pid: Int32, birth: UInt64, number: UInt32, hash: String
    var identifier: String { "net.example.nearpane-five-preview." + String(slot + 1) }
    var card: String { "current-desktop-window:\(pid):\(number)" }
}
struct FiveRun: Codable, Equatable {
    let hostPID: Int32, hostBirth: UInt64, hostHash: String, space: UInt64, display: String, spaceUUID: String
    let owners: [FiveOwner]
    var valid: Bool {
        let count = owners.count
        return count <= 5 && owners.map(\.slot) == Array(0..<count) && Set(owners.map(\.pid)).count == count &&
            Set(owners.map(\.number)).count == count && owners.allSatisfy { $0.pid > 1 && $0.pid != hostPID &&
                $0.birth > 0 && $0.number > 0 && $0.hash.count == 40 && $0.hash.allSatisfy(\.isHexDigit) } &&
            hostPID > 1 && hostBirth > 0 && hostHash.count == 40 && hostHash.allSatisfy(\.isHexDigit) &&
            space > 0 && UUID(uuidString: display) != nil && UUID(uuidString: spaceUUID) != nil
    }
}
struct FiveGeometry: Codable, Equatable {
    let panel: UInt32, sources: [[Double]], pictures: [[Double]], region: [Double], displayBounds: [Double]
}

func fiveRect(_ numbers: [Double]) -> CGRect? {
    guard numbers.count == 4, numbers.allSatisfy(\.isFinite), numbers[2] > 0, numbers[3] > 0 else { return nil }
    return CGRect(x:numbers[0], y:numbers[1], width:numbers[2], height:numbers[3])
}
