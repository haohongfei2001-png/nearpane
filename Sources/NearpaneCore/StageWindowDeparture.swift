import CoreGraphics
import Darwin
import Foundation

/// Proof for a directory edit only. No AX object or restoration authority can be reconstructed from it.
public struct StageWindowDeparture: Encodable, Sendable {
    public enum Reason: String, Encodable, Sendable { case processExit, closedWindow }
    public let window: NativeSpaceWindow, lifetime: UUID, reason: Reason
    public let firstAbsent, secondAbsent: TimeInterval

    public static func confirmed(_ closure: OrdinaryWindowClosure, original: ManagedWindowID,
                                 lifetime: UUID) -> Self? {
        guard closure.id == original, closure.destroyed >= 0, closure.destroyed <= closure.firstAbsent,
              closure.secondAbsent - closure.firstAbsent >= 0.075 else { return nil }
        return .init(window: .init(pid: original.pid, birth: original.launch, number: original.number),
                     lifetime: lifetime, reason: .closedWindow, firstAbsent: closure.firstAbsent, secondAbsent: closure.secondAbsent)
    }

    /// A process notification alone can name a recycled PID. An error reading the kernel identity
    /// is conclusive only if the kernel independently reports ESRCH. Check CG's full list both times.
    public static func exited(pid: Int32, bound: [NativeSpaceWindow: UUID]) async throws -> [Self] {
        guard pid > 1, !bound.isEmpty else { return [] }
        func absent() -> Set<NativeSpaceWindow> {
            let birth: UInt64?
            if let image = try? OrdinaryProcessImage.read(pid) { birth = image.launch }
            else {
                guard kill(pid, 0) == -1, errno == ESRCH else { return [] }
                birth = nil
            }
            return Set(bound.keys.filter { key in
                guard key.pid == pid, key.birth != birth, key.number > 0,
                      let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, key.number) else { return false }
                return CFArrayGetCount(rows) == 0
            })
        }
        let first = absent(), start = ProcessInfo.processInfo.systemUptime
        guard !first.isEmpty else { return [] }
        try await Task.sleep(for: .milliseconds(100))
        let both = first.intersection(absent()), end = ProcessInfo.processInfo.systemUptime
        return both.compactMap { key in
            bound[key].map { .init(window: key, lifetime: $0, reason: .processExit, firstAbsent: start, secondAbsent: end) }
        }
    }
}
