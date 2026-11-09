import AppKit
import CryptoKit
import NearpaneCore
import WindowLab

@MainActor final class ReadOnlyGate {
    private var child: Process?, anchor: ActiveSpaceAnchor?, began: Double = 0
    func stop() { if child?.isRunning == true { child?.terminate() } }
    func sample(member: Member, window: NSWindow, sequence: Int, run: Run, directory: URL) throws -> Bool {
        let frame = SurfaceRect(x: window.frame.minX, y: NSScreen.screens[0].frame.maxY - window.frame.maxY,
                                width: window.frame.width, height: window.frame.height)
        try require(member.id.number == UInt32(exactly: window.windowNumber) && window.isOnActiveSpace && window.isVisible
            && !window.isMiniaturized && !window.styleMask.contains(.fullScreen) && !window.collectionBehavior.contains(.canJoinAllSpaces)
            && run.screens.frame.geometry.intersection(frame.geometry) == frame.geometry, "missing active secondary fixture")
        let current = ActiveSpaceAnchor(number: member.id.number, displayID: run.screens.secondary, globalFrame: frame)
        let url = directory.appendingPathComponent("native-gate-\(sequence).json")
        if let child {
            try require(anchor == current && ProcessInfo.processInfo.systemUptime - began < 5, "gate witness expired or changed")
            if child.isRunning { return false }
            guard child.terminationStatus == 0 else { throw Refusal("read-only helper failed") }
            let sample = try JSONDecoder().decode(DesktopSnapshot.self, from: Data(contentsOf: url))
            try require(sample.isStructurallyValid && sample.sessionID == run.session && sample.revision == UInt64(sequence)
                && sample.windows.allSatisfy { $0.metadata?.pid == getpid() && $0.metadata?.number == member.id.number }
                && sample.native?.rows.allSatisfy { $0.anchor == current } == true, "out-of-scope native sample")
            self.child = nil; anchor = nil
            return true
        }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NearpaneDesktopReader")
        let data = try Data(contentsOf: helper)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try require(Bundle.main.object(forInfoDictionaryKey: "NearpaneDesktopReaderSHA256") as? String == hash, "unsealed desktop reader")
        let request = DesktopReadRequest(session: run.session, revision: UInt64(sequence), parentPID: getpid(),
                                         fixtureWindows: [member.id.number], anchors: [current], experimentalSpaces: true)
        let proc = Process(); proc.executableURL = helper
        proc.arguments = ["--read-encoded", try JSONEncoder().encode(request).base64EncodedString()]
        try Data().write(to: url, options: .withoutOverwriting)
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }
        proc.standardOutput = out; proc.standardInput = FileHandle.nullDevice
        try proc.run(); child = proc; anchor = current; began = ProcessInfo.processInfo.systemUptime
        return false
    }
}
