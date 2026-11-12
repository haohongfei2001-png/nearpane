import AppKit
import CryptoKit
import NearpaneCore
import WindowGeometryCore

@MainActor public final class NativeDesktopProvider: LiveDesktopObservationProvider {
    public let capabilities = DesktopCapabilities(observation: .readOnly)
    private let session = UUID()
    private var revision: UInt64 = 0
    private var previousOptIn = false
    private var privateFailure: SpaceReadStatus?
    private let fixtureWindows: @MainActor () -> [NSWindow]?
    typealias Read = @Sendable (DesktopReadRequest) async throws -> DesktopSnapshot
    private let read: Read
    private let anchors: @MainActor () -> [ActiveSpaceAnchor]
    private let activeNumbers: @MainActor () -> Set<UInt32>

    // Constructing a provider performs no system sampling and opens no windows.
    public static func packaged(fixtureWindows: @escaping @MainActor () -> [NSWindow]? = { nil }) -> any DesktopObservationProvider {
        guard Bundle.main.bundleURL.pathExtension == "app", let expected = Bundle.main.object(forInfoDictionaryKey: "NearpaneDesktopReaderSHA256") as? String,
              expected.count == 64 else { return UnavailableDesktopProvider() }
        guard let executable = resolvedReader(in: Bundle.main.bundleURL) else { return UnavailableDesktopProvider() }
        return NativeDesktopProvider(fixtureWindows: fixtureWindows, anchors: { currentAnchors(fixtureWindows() ?? NSApp.windows) }) { request in
            try await Task.detached(priority: .utility) {
                let bytes = try Data(contentsOf: executable, options: .mappedIfSafe)
                guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == expected else { throw ReaderFailure.unavailable }
            }.value
            return try await DesktopReaderProcess.read(executable: executable, request: request)
        }
    }

    // Foundation normalizes volume aliases such as /private/tmp to /tmp. Resolve the
    // application itself first; redirects inside Contents/Helpers are still rejected.
    static func resolvedReader(in bundle: URL) -> URL? {
        let executable = bundle.resolvingSymlinksInPath().appendingPathComponent("Contents/Helpers/NearpaneDesktopReader")
        return executable.path == executable.resolvingSymlinksInPath().path ? executable : nil
    }

    init(fixtureWindows: @escaping @MainActor () -> [NSWindow]?, anchors: @escaping @MainActor () -> [ActiveSpaceAnchor],
         activeNumbers: @escaping @MainActor () -> Set<UInt32> = {
             Set((NSWindow.windowNumbers(options: .allApplications) ?? []).compactMap { UInt32(exactly: $0.int64Value) })
         }, read: @escaping Read) {
        self.fixtureWindows = fixtureWindows; self.anchors = anchors; self.activeNumbers = activeNumbers; self.read = read
    }

    static func currentAnchors(_ windows: [NSWindow]) -> [ActiveSpaceAnchor] {
        // NSWindow supplies the public active-Space fact only for windows this process owns.
        windows.compactMap { w -> ActiveSpaceAnchor? in
            guard !(w is NSPanel), w.windowNumber > 0, w.level == .normal, w.isVisible, !w.isMiniaturized,
                  w.isOnActiveSpace, w.occlusionState.contains(.visible), !w.styleMask.contains(.fullScreen),
                  !w.collectionBehavior.contains(.canJoinAllSpaces), !w.collectionBehavior.contains(.moveToActiveSpace),
                  let screen = w.screen, NSContainsRect(screen.frame, w.frame),
                  let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  CGDisplayIsInMirrorSet(n.uint32Value) == 0,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue(),
                  let turn = QuarterTurn(rawValue: Int(CGDisplayRotation(n.uint32Value).rounded()) % 360) else { return nil }
            func rect(_ r: CGRect) -> Rect { Rect(r.minX, r.minY, r.width, r.height) }
            let id = CFUUIDCreateString(nil, uuid) as String
            guard let map = try? DisplayCoordinateTransform(displayID: id, appKitFrame: rect(screen.frame), cgBounds: rect(CGDisplayBounds(n.uint32Value)),
                backingScale: screen.backingScaleFactor, rotation: turn), let global = try? map.appKitToCG(rect(w.frame)) else { return nil }
            return ActiveSpaceAnchor(number: UInt32(w.windowNumber), displayID: id, globalFrame: .init(global))
        }.prefix(16).map { $0 }
    }

    public func snapshot(experimentalSpaces: Bool) async throws -> DesktopSnapshot {
        revision += 1
        let current = revision
        if previousOptIn != experimentalSpaces { privateFailure = nil; previousOptIn = experimentalSpaces }
        let witnesses = experimentalSpaces ? anchors() : []
        let ids = fixtureWindows()?.compactMap { UInt32(exactly: $0.windowNumber) }
        func request(_ experimental: Bool) -> DesktopReadRequest {
            DesktopReadRequest(session: session, revision: current, parentPID: getpid(), fixtureWindows: ids,
                               anchors: experimental ? witnesses : [], experimentalSpaces: experimental)
        }
        let attemptPrivate = experimentalSpaces && privateFailure == nil
        var result: DesktopSnapshot
        var usedPrivate = attemptPrivate
        do {
            result = try await read(request(attemptPrivate))
        } catch {
            try Task.checkCancellation()
            guard attemptPrivate, current == revision else { throw error }
            privateFailure = .unavailable
            usedPrivate = false
            result = try await read(request(false))
        }
        try Task.checkCancellation()
        guard current == revision, result.sessionID == session, result.revision == current, result.isStructurallyValid,
              let evidence = result.native, evidence.population == (ids == nil ? .workWindows : .markedFixture),
              usedPrivate || evidence.spaces == .disabled else { throw ReaderFailure.invalidResponse }
        if let ids {
            guard result.windows.allSatisfy({ w in
                w.metadata.map { $0.pid == getpid() && ids.contains($0.number) } ?? false
            }) else { throw ReaderFailure.invalidResponse }
        }
        if attemptPrivate, let status = result.native?.spaces, [.unavailable, .unsupportedBuild].contains(status) { privateFailure = status }
        if experimentalSpaces, let privateFailure { result.native?.spaces = privateFailure }
        if result.native?.rows.isEmpty == false {
            let stillCurrent = anchors()
            let active = evidence.rows.contains { $0.anchor.witness == .appKitActiveList } ? activeNumbers() : []
            if evidence.rows.contains(where: { row in
                switch row.anchor.witness {
                case .ownedWindow: return !witnesses.contains(row.anchor) || !stillCurrent.contains(row.anchor)
                case .appKitActiveList: return ids != nil || !active.contains(row.anchor.number)
                }
            }) {
                result.native?.rows = []; result.userSpaceSemantics = .unknown; result.topologyConsistent = false; result.freshness = .transient
            }
        }
        guard result.isStructurallyValid else { throw ReaderFailure.invalidResponse }
        return result
    }
}
