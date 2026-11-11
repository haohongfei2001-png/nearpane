import Foundation

/// Only the disposable reader interprets this request. An empty selection lists numbers;
/// detail reads have explicit window numbers and an incarnation of one local process.
public struct AdmissionReadRequest: Codable, Sendable {
    public struct Target: Codable, Sendable {
        public let number: UInt32
        public let registeredIdentifier: String?
        public init(number: UInt32, registeredIdentifier: String? = nil) {
            self.number = number; self.registeredIdentifier = registeredIdentifier
        }
    }
    public let parent: Int32, pid: Int32, launch: UInt64, bundle: String, nonce: UUID
    public let targets: [Target]
    public init(parent: Int32, pid: Int32, launch: UInt64, bundle: String, targets: [Target]) {
        self.parent = parent; self.pid = pid; self.launch = launch; self.bundle = bundle
        self.targets = targets; nonce = UUID()
    }
}
public struct AdmissionReadReply: Codable, Sendable {
    public let nonce: UUID, permitted: Bool, numbers: [UInt32?], pairs: [AdmissionPair]
    public init(nonce: UUID, permitted: Bool, numbers: [UInt32?], pairs: [AdmissionPair]) {
        self.nonce = nonce; self.permitted = permitted; self.numbers = numbers; self.pairs = pairs
    }
}
