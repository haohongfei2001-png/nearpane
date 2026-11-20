// ScreenCaptureKit display stream of the two enrolled fixture window IDs.
// The desktop, menu bar, overlays, child windows, pointer and audio are excluded.
// Real frames stay in bounded memory until the caller revalidates the fixture identities.
import AppKit
import AVFoundation
import CryptoKit
import CoreMedia
import Darwin
import ScreenCaptureKit

private typealias JSON = [String: Any]
private struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
private struct Space: Codable, Equatable { let id: UInt64, type: Int, uuid: UUID }
private struct Topology: Codable { let display: UUID, records: [Space], current: UInt64 }
private struct Window: Codable { let pid: pid_t, birth: UInt64, number: UInt32, executable: String, identifier: String }
private struct Pair: Codable { let topology: Topology, sourceWindow: Window, targetWindow: Window, target: UInt64, hostPID: pid_t, hid: [UInt32] }
private struct Binding: Codable { let nonce: UUID, guardian: pid_t, guardianBirth: UInt64, request: Pair; let endpoints: [String: Endpoint]? }
private struct Endpoint: Codable {
    let space: UInt64, display: UUID, wallpaper: String, crop: [Double], rgb: [Int]
}
private struct End: Codable { let nonce: UUID, allowMovie: Bool, pressed: Double, ended: Double }
private let uptime = { ProcessInfo.processInfo.systemUptime }

private func json(_ value: JSON, _ url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url, options: .atomic)
}

private func birth(_ pid: pid_t) -> UInt64? {
    var info = proc_bsdinfo()
    let n = Int32(MemoryLayout.size(ofValue: info))
    guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, n) == n,
          info.pbi_pid == UInt32(pid), info.pbi_uid == getuid(), info.pbi_start_tvsec > 0 else { return nil }
    return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
}

private func hardware() -> [UInt32] {
    [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel,
     .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].map { CGEventSource.counterForEventType(.hidSystemState, eventType: $0) }
}

private func pairIntact(_ p: Pair) -> Bool {
    hardware() == p.hid && [p.sourceWindow, p.targetWindow].allSatisfy { w in
        guard birth(w.pid) == w.birth else { return false }
        var path = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(w.pid, &path, UInt32(path.count)) > 0 && String(cString: path) == w.executable
    }
}

// This is an independent metadata read after a callback. ScreenCaptureKit does not provide
// an atomic physical-layer census for a displayTime. Unknown window identities never leave this process.
private func inventory(_ p: Pair) -> (UInt64?, [UInt32]?) {
    guard let rows = NPReadInventory() as? [JSON], rows.count == 1, let row = rows.first,
          let display = row["Display Identifier"] as? String, UUID(uuidString: display) == p.topology.display,
          let spaces = row["Spaces"] as? [JSON], spaces.count == p.topology.records.count else { return (nil, nil) }
    for (a, b) in zip(spaces, p.topology.records) {
        guard a["id64"] as? UInt64 == b.id, a["type"] as? Int == b.type,
              UUID(uuidString: a["uuid"] as? String ?? "") == b.uuid else { return (nil, nil) }
    }
    let current = (row["Current Space"] as? JSON)?["id64"] as? UInt64
    // Only the window numbers enter the receipt. Foreign titles and application names are never read.
    let ordered = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [JSON])?.compactMap {
        $0[kCGWindowNumber as String] as? UInt32
    }
    return (current, ordered)
}

private func wallpaper(_ screen: NSScreen) -> String? {
    guard let file = NSWorkspace.shared.desktopImageURL(for: screen)?.resolvingSymlinksInPath(),
          file.path.hasPrefix("/System/Library/Desktop Pictures/"),
          ["heic", "jpg", "jpeg", "png", "tif", "tiff"].contains(file.pathExtension.lowercased()) else { return nil }
    var info = stat()
    guard lstat(file.path, &info) == 0, info.st_uid == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
    let fingerprint = file.path + "/" + String(info.st_ino) + "/" + String(info.st_size) + "/" + String(info.st_mtimespec.tv_sec)
    return SHA256.hash(data: Data(fingerprint.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func layerAtProbe(_ crop: CGRect, _ pair: Pair) -> UInt32? {
    guard let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [JSON] else { return nil }
    for row in rows {
        guard let bounds = row[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              let layer = row[kCGWindowLayer as String] as? Int, let wid = row[kCGWindowNumber as String] as? UInt32,
              let pid = row[kCGWindowOwnerPID as String] as? pid_t, let alpha = row[kCGWindowAlpha as String] as? Double else { return nil }
        guard alpha > 0, rect.intersects(crop) else { continue }
        if let owned = [pair.sourceWindow, pair.targetWindow].first(where: { $0.number == wid && $0.pid == pid }), birth(pid) == owned.birth {
            if alpha >= 0.999 && rect.insetBy(dx: 12, dy: 12).contains(crop) { return owned.number }
            continue
        }
        // A transparent Finder desktop/icon plane, menu, popover or sidebar has unknown coverage. It cannot be assumed empty.
        if layer < Int(CGWindowLevelForKey(.desktopWindow)) {
            var exe = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &exe, UInt32(exe.count)) > 0 else { return nil }
            let path = String(cString: exe)
            return rect.contains(crop) && (path == "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer" ||
                (path.hasPrefix("/System/Library/") && path.hasSuffix("/WallpaperAgent"))) ? 0 : nil
        }
        return nil
    }
    return nil
}

private func rgb(_ img: CGImage) -> [Int]? {
    var data = [UInt8](repeating: 0, count: 4)
    return data.withUnsafeMutableBytes { bytes in
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB), let c = CGContext(data: bytes.baseAddress, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.interpolationQuality = .high; c.draw(img, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard bytes[3] >= 245 else { return nil }
        return [Int(bytes[0]), Int(bytes[1]), Int(bytes[2])]
    }
}

private func cleanDesktops(_ p: Pair) -> Bool {
    let ids = [p.topology.current, p.target]
    guard let census = NPContractMemberReport(ids as CFArray, p.hostPID) as? [String: JSON] else { return false }
    return zip(ids, [p.sourceWindow, p.targetWindow]).allSatisfy { sid, window in
        guard let data = census[String(sid)], data["otherMembers"] as? Int == 0, data["unresolved"] as? Int == 0,
              let members = data["ordinary"] as? [JSON], members.contains(where: { $0["number"] as? UInt32 == window.number && $0["pid"] as? pid_t == window.pid }) else { return false }
        return members.allSatisfy { member in [p.sourceWindow,p.targetWindow].contains { member["pid"] as? pid_t == $0.pid && birth($0.pid) == $0.birth } }
    }
}

private func probeRect(_ pair: [SCWindow], display: SCDisplay) -> CGRect? {
    let overlap = pair[0].frame.intersection(pair[1].frame).intersection(display.frame).insetBy(dx: 24, dy: 24)
    guard !overlap.isNull, overlap.width >= 32, overlap.height >= 32 else { return nil }
    return CGRect(x: floor(overlap.midX - 12), y: floor(overlap.midY - 12), width: 24, height: 24)
}

private func rectangle(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height] }

private func probeConfiguration(_ r: CGRect, _ display: SCDisplay, _ hz: Int) -> SCStreamConfiguration {
    let c = SCStreamConfiguration()
    c.sourceRect = r.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
    c.width = 4; c.height = 4
    c.pixelFormat = kCVPixelFormatType_32BGRA
    c.minimumFrameInterval = CMTime(value: 1, timescale: Int32(hz))
    c.showsCursor = false; c.capturesAudio = false; c.captureMicrophone = false; c.includeChildWindows = false
    return c
}

// Independent display-mode stream. The only emitted pixel information is a quantized
// mean from a prequalified 24-point rectangle; this stream never writes video or an image.
private final class DisplayProbe: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let pair: Pair, crop: CGRect, screen: NSScreen, endpoints: [String: Endpoint]
    private(set) var rows = [JSON](), failed = false
    private var scale = mach_timebase_info_data_t()
    init(_ pair: Pair, _ crop: CGRect, _ screen: NSScreen, _ endpoints: [String: Endpoint]) {
        self.pair = pair; self.crop = crop; self.screen = screen; self.endpoints = endpoints
        super.init(); mach_timebase_info(&scale)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { DispatchQueue.main.async { self.failed = true } }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, rows.count < 6_000 else { return }
        let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first
        let ticks = (info?[.displayTime] as? NSNumber)?.uint64Value ?? 0
        let time = Double(ticks) * Double(scale.numer) / Double(scale.denom) / 1e9
        let status = info?[.status] as? Int ?? -1
        let space = inventory(pair).0
        var row: JSON = ["displayTime": time, "callback": uptime(), "status": status, "space": space as Any? ?? NSNull(), "safe": false]
        defer { rows.append(row) }
        guard pairIntact(pair), let space, let expected = endpoints[String(space)], wallpaper(screen) == expected.wallpaper,
              let visible = layerAtProbe(crop, pair) else { return }
        var color: [Int]?
        if status == SCFrameStatus.complete.rawValue || status == SCFrameStatus.started.rawValue,
           let pix = CMSampleBufferGetImageBuffer(sample), CVPixelBufferGetWidth(pix) == 4, CVPixelBufferGetHeight(pix) == 4,
           CVPixelBufferGetPixelFormatType(pix) == kCVPixelFormatType_32BGRA, CVPixelBufferLockBaseAddress(pix, .readOnly) == kCVReturnSuccess {
            defer { CVPixelBufferUnlockBaseAddress(pix, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(pix) else { return }
            var channels = [Int](repeating: 0, count: 3)
            for y in 0..<4 {
                let line = base.advanced(by: y*CVPixelBufferGetBytesPerRow(pix)).assumingMemoryBound(to: UInt8.self)
                for x in 0..<4 {
                    guard line[x*4+3] >= 245 else { return }
                    for k in 0..<3 { channels[k] += Int(line[x*4+2-k]) }
                }
            }
            color = channels.map { (($0 / 16 + 4) / 8) * 8 }
        }
        guard inventory(pair).0 == space, layerAtProbe(crop, pair) == visible, pairIntact(pair) else { return }
        row["safe"] = true
        row["visible"] = visible == pair.sourceWindow.number ? "source" : (visible == pair.targetWindow.number ? "target" : "appleWallpaper")
        if let color {
            row["lit"] = (color.max() ?? 0) > 24
            row["matchesSource"] = comparison(color, endpoints[String(pair.topology.current)]?.rgb)
            row["matchesTarget"] = comparison(color, endpoints[String(pair.target)]?.rgb)
        }
    }
    /// Static desktops can stop delivering changed frames. Read the same guarded display crop only
    /// during that silence. Capture bounds travel with the sample; slow captures cannot fill gaps.
    @MainActor func sampleIfIdle(filter: SCContentFilter, config: SCStreamConfiguration) async {
        let start = uptime()
        guard rows.count < 6_000, start - (rows.last?["callback"] as? Double ?? 0) > 0.022,
              pairIntact(pair), let space = inventory(pair).0, let expected = endpoints[String(space)],
              wallpaper(screen) == expected.wallpaper, let surface = layerAtProbe(crop, pair) else { return }
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return }
        let end = uptime()
        let visible = surface == pair.sourceWindow.number ? "source" : (surface == pair.targetWindow.number ? "target" : "appleWallpaper")
        var row: JSON = ["displayTime": (start + end)/2, "from": start, "to": end, "callback": end,
                         "origin": "guarded-current-display-crop", "status": 0, "safe": false, "space": space]
        defer { rows.append(row) }
        guard end - start <= 0.050, image.width == 4, image.height == 4, let color = rgb(image),
              pairIntact(pair), inventory(pair).0 == space, layerAtProbe(crop, pair) == surface,
              wallpaper(screen) == expected.wallpaper else { return }
        row["safe"] = true; row["visible"] = visible; row["lit"] = (color.max() ?? 0) > 24
        row["matchesSource"] = comparison(color, endpoints[String(pair.topology.current)]?.rgb)
        row["matchesTarget"] = comparison(color, endpoints[String(pair.target)]?.rgb)
    }
    private func comparison(_ sample: [Int], _ expected: [Int]?) -> Bool {
        guard let expected, expected.count == 3 else { return false }
        return zip(sample, expected).allSatisfy { abs($0 - $1) <= 30 }
    }
}

private struct Picture { let time: Double, bytes: Data }
private final class Frames: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "nearpane.acceptance.visual")
    let request: Pair, width: Int, height: Int
    private let lock = NSLock()
    private(set) var records = [JSON](), pictures = [Picture]()
    private var totalBytes = 0
    private(set) var droppedMovie = false, identityChanged = false, stoppedEarly = false
    private var scale = mach_timebase_info_data_t()

    init(_ request: Pair, width: Int, height: Int) {
        self.request = request; self.width = width; self.height = height
        super.init()
        mach_timebase_info(&scale)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock { stoppedEarly = true }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        let received = uptime()
        let attachment = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first
        let status = attachment?[.status] as? Int
        let labels = ["complete", "idle", "blank", "suspended", "started", "stopped"]
        let name = status.flatMap { labels.indices.contains($0) ? labels[$0] : nil } ?? "unknown"
        let ticks = (attachment?[.displayTime] as? NSNumber)?.uint64Value ?? 0
        let when = ticks == 0 ? nil : Double(ticks) * Double(scale.numer) / Double(scale.denom) / 1e9
        let (space, order) = inventory(request)
        let source = request.sourceWindow.number, target = request.targetWindow.number
        let visible = order.map { $0.filter { $0 == source || $0 == target } }
        var row: JSON = ["callback": received, "status": name, "ticks": ticks, "displayTime": when as Any? ?? NSNull(),
                         "space": space as Any? ?? NSNull(), "visibleEnrolled": visible as Any? ?? NSNull()]
        if let order, let foremost = order.firstIndex(where: { $0 == source || $0 == target }) {
            row["otherWindowsAhead"] = foremost
        }
        let intact = pairIntact(request) && [request.topology.current, request.target].contains(space ?? 0)
        row["identitiesIntact"] = intact
        var image: Picture?
        if intact, (name == "complete" || name == "started"), let when,
           let buf = CMSampleBufferGetImageBuffer(sample), CVPixelBufferGetWidth(buf) == width,
           CVPixelBufferGetHeight(buf) == height, CVPixelBufferGetPixelFormatType(buf) == kCVPixelFormatType_32BGRA,
           CVPixelBufferLockBaseAddress(buf, .readOnly) == kCVReturnSuccess {
            defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
            if let address = CVPixelBufferGetBaseAddress(buf) {
                let step = CVPixelBufferGetBytesPerRow(buf)
                var opaque = 0, dark = 0, transparent = 0, anyLight = 0
                var bytes = Data(capacity: width * height * 4)
                for y in 0..<height {
                    let start = address.advanced(by: step * y).assumingMemoryBound(to: UInt8.self)
                    bytes.append(start, count: width * 4)
                    for x in 0..<width {
                        let c = start.advanced(by: x * 4), a = c[3]
                        if a <= 4 { transparent += 1 }
                        if a >= 250 {
                            opaque += 1
                            if max(c[0], c[1], c[2]) <= 12 { dark += 1 } else { anyLight += 1 }
                        }
                    }
                }
                row["opaque"] = opaque; row["dark"] = dark; row["transparent"] = transparent; row["lit"] = anyLight
                image = Picture(time: when, bytes: bytes)
            }
        }
        lock.withLock {
            identityChanged = identityChanged || !intact
            if records.count < 6_000 { records.append(row) } else { stoppedEarly = true }
            if identityChanged || totalBytes + (image?.bytes.count ?? 0) > 64 * 1024 * 1024 {
                droppedMovie = true
                pictures.removeAll(keepingCapacity: false)
            }
            if let image, !droppedMovie {
                totalBytes += image.bytes.count
                pictures.append(image)
            }
        }
    }

    func ready() -> Bool {
        lock.withLock {
            !identityChanged && records.contains {
                $0["space"] as? UInt64 == request.topology.current &&
                ($0["visibleEnrolled"] as? [UInt32])?.contains(request.sourceWindow.number) == true &&
                ($0["opaque"] as? Int ?? 0) >= 4
            }
        }
    }
    func completed() -> ([JSON], [Picture], Bool, Bool, Bool) {
        lock.withLock { (records, pictures, droppedMovie, identityChanged, stoppedEarly) }
    }
}

private func writeMovie(_ pictures: [Picture], width: Int, height: Int, to url: URL) async throws {
    guard let first = pictures.first, let last = pictures.last, last.time > first.time else { throw Failure("fewer than two distinct captured frames") }
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
    let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
    guard writer.canAdd(input) else { throw Failure("silent video output unavailable") }
    writer.add(input)
    guard writer.startWriting() else { throw Failure("video writer did not start") }
    writer.startSession(atSourceTime: .zero)
    let deadline = uptime() + 7
    var previous = -1.0
    for frame in pictures where frame.time > previous {
        previous = frame.time
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing, uptime() < deadline else { throw Failure("video writer stalled") }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard let pool = adapter.pixelBufferPool else { throw Failure("video pool missing") }
        var result: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &result) == kCVReturnSuccess, let result,
              CVPixelBufferLockBaseAddress(result, []) == kCVReturnSuccess else { throw Failure("video buffer unavailable") }
        guard let address = CVPixelBufferGetBaseAddress(result) else { CVPixelBufferUnlockBaseAddress(result, []); throw Failure("video mapping unavailable") }
        frame.bytes.withUnsafeBytes { src in
            let source = src.bindMemory(to: UInt8.self)
            for y in 0..<height {
                let line = address.advanced(by: y * CVPixelBufferGetBytesPerRow(result)).assumingMemoryBound(to: UInt8.self)
                let row = y * width * 4
                for x in stride(from: 0, to: width * 4, by: 4) {
                    let missing = 255 - Int(source[row+x+3])
                    for k in 0..<3 { line[x+k] = UInt8(min(255, Int(source[row+x+k]) + missing * 84 / 255)) }
                    line[x+3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(result, [])
        guard adapter.append(result, withPresentationTime: CMTime(seconds: frame.time - first.time, preferredTimescale: 60_000)) else {
            throw Failure("video append failed")
        }
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw Failure("video writer failed") }
    let asset = AVURLAsset(url: url)
    guard try await asset.loadTracks(withMediaType: .video).count == 1,
          try await asset.loadTracks(withMediaType: .audio).isEmpty else { throw Failure("invalid silent movie tracks") }
}

@main private struct P0Visual {
    @MainActor static func main() async {
        guard [2,3].contains(CommandLine.arguments.count) else { exit(2) }
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--test-encoder" {
            let path = URL(fileURLWithPath: CommandLine.arguments[2])
            guard !FileManager.default.fileExists(atPath: path.path) else { exit(2) }
            let frames = (0..<6).map { index in
                Picture(time: Double(index) / 30, bytes: Data(repeating: UInt8(30 + index * 20), count: 64 * 32 * 4))
            }
            do { try await writeMovie(frames, width: 64, height: 32, to: path) } catch { exit(2) }
            return
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        do { try await capture(directory) }
        catch {
            try? json(["error": (error as? Failure)?.message ?? "native display stream unavailable"], directory.appendingPathComponent("error.json"))
            exit(2)
        }
    }

    @MainActor private static func capture(_ directory: URL) async throws {
        let b = try JSONDecoder().decode(Binding.self, from: Data(contentsOf: directory.appendingPathComponent("binding.json")))
        let p = b.request
        guard CGPreflightScreenCaptureAccess(), NPReadOnlySpacesOpen() == 1, birth(b.guardian) == b.guardianBirth,
              pairIntact(p), inventory(p).0 == p.topology.current else { throw Failure("screen permission, guardian, source or fixture unavailable") }
        let all = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let displays = all.displays.filter {
            guard let uuid = CGDisplayCreateUUIDFromDisplayID($0.displayID)?.takeRetainedValue() else { return false }
            return UUID(uuidString: CFUUIDCreateString(nil, uuid) as String) == p.topology.display
        }
        guard displays.count == 1, let display = displays.first, CGDisplayIsActive(display.displayID) != 0,
              CGDisplayIsInMirrorSet(display.displayID) == 0, CGDisplayIsAsleep(display.displayID) == 0,
              let screen = NSScreen.screens.first(where: { ($0.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID }) else {
            throw Failure("active physical display could not be matched")
        }
        let included = try [p.sourceWindow,p.targetWindow].map { w -> SCWindow in
            let names = ["org.nearpane.acceptance.LifecycleWindow", "net.example.spaces-route-witness", "net.example.spaces-document"]
            let matches = all.windows.filter { $0.windowID == w.number && $0.owningApplication?.processID == w.pid && $0.owningApplication?.bundleIdentifier == w.identifier }
            guard names.contains(w.identifier), w.executable.hasPrefix("/private/tmp/nearpane-d01."), matches.count == 1, let only = matches.first else {
                throw Failure("ScreenCaptureKit cannot bind both enrolled fixtures, including the off-Space endpoint")
            }
            return only
        }
        let allowed = Set(included.map(\.windowID))
        guard allowed.count == 2 else { throw Failure("window identity collision") }
        let crop = probeRect(included, display: display)
        let hz = max(1, min(60, screen.maximumFramesPerSecond))
        if CommandLine.arguments.last == "enroll" {
            guard let crop, let wall = wallpaper(screen), cleanDesktops(p), layerAtProbe(crop, p) == p.sourceWindow.number else {
                throw Failure("both exclusive ordinary fixture desktops, a sealed Apple wallpaper and unobstructed common rectangle are required")
            }
            let sourceOnly = SCContentFilter(display: display, including: [included[0]])
            sourceOnly.includeMenuBar = false
            let shot = try await SCScreenshotManager.captureImage(contentFilter: sourceOnly, configuration: probeConfiguration(crop, display, hz))
            guard let color = rgb(shot), (color.max() ?? 0) > 45, pairIntact(p), inventory(p).0 == p.topology.current,
                  layerAtProbe(crop, p) == p.sourceWindow.number, wallpaper(screen) == wall else { throw Failure("controlled visible fixture color unavailable") }
            let ep = Endpoint(space: p.topology.current, display: p.topology.display, wallpaper: wall, crop: rectangle(crop), rgb: color)
            try JSONEncoder().encode(ep).write(to: directory.appendingPathComponent("endpoint.json"), options: .atomic)
            return
        }
        var probe: DisplayProbe?, observerStream: SCStream?, staticCropTask: Task<Void, Never>?
        if let crop, let endpoints = b.endpoints, let a = endpoints[String(p.topology.current)], let z = endpoints[String(p.target)],
           a.display == p.topology.display, z.display == p.topology.display, a.space == p.topology.current, z.space == p.target,
           a.crop == rectangle(crop), z.crop == a.crop, a.rgb.count == 3, z.rgb.count == 3,
           zip(a.rgb,z.rgb).contains(where: { abs($0 - $1) > 60 }), a.wallpaper == wallpaper(screen), cleanDesktops(p), layerAtProbe(crop, p) == p.sourceWindow.number {
            // Display excluding (not group-of-windows) retains the macOS desktop composition.
            // Exclude every shareable application except the two registered synthetic window owners
            // and Apple's wallpaper agent, then reject any unverified physical layer above the probe.
            let allowedPIDs = Set([p.sourceWindow.pid, p.targetWindow.pid])
            let excluded = all.applications.filter { app in
                if allowedPIDs.contains(app.processID) { return false }
                guard app.bundleIdentifier == "com.apple.wallpaper.agent" else { return true }
                var path = [CChar](repeating: 0, count: 4096)
                guard proc_pidpath(app.processID, &path, UInt32(path.count)) > 0 else { return true }
                let exe = String(cString: path)
                return !(exe.hasPrefix("/System/Library/") && exe.hasSuffix("/WallpaperAgent"))
            }
            let displayFilter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
            displayFilter.includeMenuBar = false
            let observer = DisplayProbe(p, crop, screen, endpoints)
            let probeConfig = probeConfiguration(crop, display, hz)
            let independent = SCStream(filter: displayFilter, configuration: probeConfig, delegate: observer)
            do {
                guard displayFilter.style == .display else { throw Failure("independent probe is not a display-bound stream") }
                try independent.addStreamOutput(observer, type: .screen, sampleHandlerQueue: .main)
                try await independent.startCapture()
                probe = observer; observerStream = independent
                staticCropTask = Task { @MainActor in
                    while !Task.isCancelled {
                        await observer.sampleIfIdle(filter: displayFilter, config: probeConfig)
                        do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                    }
                }
            } catch { try? await independent.stopCapture() }
        }
        let filter = SCContentFilter(display: display, including: included)
        filter.includeMenuBar = false
        guard Set(filter.includedWindows.map(\.windowID)) == allowed,
              Set(filter.includedApplications.map(\.processID)).isSubset(of: Set([p.sourceWindow.pid, p.targetWindow.pid])) else {
            throw Failure("ScreenCaptureKit did not echo the exact window allowlist")
        }
        let config = SCStreamConfiguration()
        let width = 192, height = min(512, max(2, 2 * Int((Double(width) * display.frame.height / display.frame.width / 2).rounded())))
        config.width = width; config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(hz))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false; config.capturesAudio = false; config.captureMicrophone = false
        config.includeChildWindows = false; config.shouldBeOpaque = false; config.queueDepth = 5
        let output = Frames(p, width: width, height: height)
        let stream = SCStream(filter: filter, configuration: config, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        try await stream.startCapture()
        let start = uptime(), deadline = start + 25
        let endFile = directory.appendingPathComponent("end.json")
        var ready = false, end: End?
        while uptime() < deadline && birth(b.guardian) == b.guardianBirth {
            if !ready, output.ready() {
                try json(["ready": true, "nonce": b.nonce.uuidString, "start": start, "pid": getpid(), "display": p.topology.display.uuidString],
                         directory.appendingPathComponent("ready.json"))
                ready = true
            }
            if let bytes = try? Data(contentsOf: endFile), let e = try? JSONDecoder().decode(End.self, from: bytes), e.nonce == b.nonce {
                end = e; break
            }
            if !ready && uptime() - start > 5 { break }
            try await Task.sleep(for: .milliseconds(12))
        }
        try? await stream.stopCapture()
        staticCropTask?.cancel()
        await staticCropTask?.value
        if let observerStream { try? await observerStream.stopCapture() }
        output.queue.sync {}
        let (records, pictures, discarded, changed, failed) = output.completed()
        let post = inventory(p).0
        var saved = false
        let destination = directory.appendingPathComponent("verified-pair.mp4")
        let pending = directory.appendingPathComponent(".writing-" + b.nonce.uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: pending) }
        if let end, end.allowMovie, end.pressed > 0, end.ended > end.pressed, ready, !changed, !failed, !discarded,
           birth(b.guardian) == b.guardianBirth, pairIntact(p), post == p.target {
            do {
                try await writeMovie(pictures, width: width, height: height, to: pending)
                if pairIntact(p) && inventory(p).0 == p.target {
                    try FileManager.default.moveItem(at: pending, to: destination)
                    saved = true
                }
            } catch {}
        }
        try json(["nonce": b.nonce.uuidString, "ready": ready, "display": p.topology.display.uuidString,
                  "requestedHz": hz, "refreshLimitHz": screen.maximumFramesPerSecond, "displayModeHz": CGDisplayCopyDisplayMode(display.displayID)?.refreshRate ?? 0,
                  "width": width, "height": height, "filterStyle": filter.style.rawValue,
                  "windows": allowed.sorted(), "wallpaperIncluded": false, "audioEnabled": false,
                  "physical": ["armed": probe != nil, "censusAfter": probe != nil && cleanDesktops(p),
                               "filter": "display-excluding-other-apps", "crop": crop.map(rectangle) as Any? ?? NSNull(),
                               "error": probe?.failed ?? false, "frames": probe?.rows ?? []] as JSON,
                  "changed": changed, "stoppedEarly": failed, "start": start, "stop": uptime(), "postSpace": post as Any? ?? NSNull(),
                  "movie": saved, "memoryCapExceeded": discarded && !changed, "frames": records],
                 directory.appendingPathComponent("frames.json"))
    }
}
