import AppKit
import ScreenCaptureKit

private typealias VisualRow = [String: Any]
private func visualNow() -> Double { ProcessInfo.processInfo.systemUptime }

enum PairVisualFailure: String, Error {
    case invalidBinding, inaccessibleDisplay, displayOrSpaceChanged, enrollmentChanged, userSuperseded
    case foregroundIntersectsCrop, foregroundCoverageUnknown, obscuredOrUncertainCrop, geometryChanged, displayStreamUnavailable
    case noSourcePresentationBeforeClick, streamInterrupted, clockChanged, presentationUnbounded
    case pixelBufferUnavailable, wrongPixelFormat, invalidRasterGeometry, insufficientROISamples, pixelBufferUnreadable
    case transparentMarker, offPaletteMarker, mixedMarker, ambiguousSurface, noTargetPresentation
    case inputTimesUnavailable, targetPrecededClick, nativeClockUnavailable, noBracketedPresentation
}

// Totals over front-to-back snapshots. No identifying information about other windows is retained.
struct PairStackCoverage {
    var enrolledRows = 0, disjointFront = 0, transparentFront = 0, behindOpaque = 0
    var intersectingFront = 0, unknownFront = 0

    var receipt: [String: Int] {
        ["verifiedEnrolledRows": enrolledRows, "frontDisjoint": disjointFront,
         "frontTransparent": transparentFront, "behindOpaqueEnrolledWindow": behindOpaque,
         "frontIntersecting": intersectingFront, "frontCoverageUnknown": unknownFront]
    }
}

struct PairPhysicalSample {
    let from: Double, to: Double
    let slot: Int
}

struct PairVisualFrame {
    let slot: Int, ticks: UInt64, time: Double, callback: Double
    let before: PairPhysicalSample, after: PairPhysicalSample

    var receipt: [String: Any] {
        ["slot": slot, "presentationMachTicks": ticks, "displayUptime": time, "callback": callback,
         "stackBefore": [before.from, before.to, Double(before.slot)], "stackAfter": [after.from, after.to, Double(after.slot)]]
    }
}

// The stream contains the two signed fixture windows over a transparent background. Map only
// the common 8-point square, using the actual output raster and its top-left clean aperture.
enum PairFocusRaster {
    struct Reading {
        var slot: Int?, issue: PairVisualFailure?, record: [String: Any] = [:]
    }

    static func measure(_ buffer: CMSampleBuffer, display: CGRect, crop: CGRect) -> Reading {
        guard let image = buffer.imageBuffer, let format = buffer.formatDescription else {
            return Reading(issue: .pixelBufferUnavailable)
        }
        let clean = CMVideoFormatDescriptionGetCleanAperture(format, originIsAtTopLeft: true)
        return measure(image, display: display, crop: crop, clean: clean)
    }

    static func measure(_ image: CVPixelBuffer, display: CGRect, crop: CGRect, clean: CGRect, minimumSide: Int = 8) -> Reading {
        let w = CVPixelBufferGetWidth(image), h = CVPixelBufferGetHeight(image)
        let format = CVPixelBufferGetPixelFormatType(image)
        var info: [String: Any] = ["size": [w, h], "pixelFormat": format]
        func reject(_ issue: PairVisualFailure) -> Reading { Reading(issue: issue, record: info) }
        guard format == kCVPixelFormatType_32BGRA, !CVPixelBufferIsPlanar(image) else { return reject(.wrongPixelFormat) }
        guard w > 0, h > 0, w <= 16384, h <= 16384, !clean.isEmpty,
              CGRect(x: 0, y: 0, width: w, height: h).contains(clean),
              display.width > 0, display.height > 0, display.contains(crop), crop.width == 8, crop.height == 8 else {
            return reject(.invalidRasterGeometry)
        }
        let sx = clean.width / display.width, sy = clean.height / display.height
        // Permit the at-most-one-pixel rounding from the capture's even dimensions.
        guard abs(clean.height - clean.width * display.height / display.width) <= 1.01 else { return reject(.invalidRasterGeometry) }
        let x0 = Int(ceil(clean.minX + (crop.minX - display.minX) * sx))
        let x1 = Int(floor(clean.minX + (crop.maxX - display.minX) * sx))
        let y0 = Int(ceil(clean.minY + (crop.minY - display.minY) * sy))
        let y1 = Int(floor(clean.minY + (crop.maxY - display.minY) * sy))
        info["cleanAperture"] = [clean.minX, clean.minY, clean.width, clean.height]
        info["pixelsPerPoint"] = [sx, sy]
        info["pixelRect"] = [x0, y0, x1 - x0, y1 - y0]
        guard x0 >= 0, y0 >= 0, x1 <= w, y1 <= h, x1 - x0 >= minimumSide, y1 - y0 >= minimumSide,
              x1 - x0 <= 64, y1 - y0 <= 64 else { return reject(.insufficientROISamples) }
        guard CVPixelBufferGetBytesPerRow(image) >= w * 4, CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess else {
            return reject(.pixelBufferUnreadable)
        }
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(image)?.assumingMemoryBound(to: UInt8.self) else { return reject(.pixelBufferUnreadable) }
        let stride = CVPixelBufferGetBytesPerRow(image)
        var count = [0, 0], alpha = 0, other = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let p = base + y * stride + x * 4
                if p[3] != 255 { alpha += 1 }
                else if let slot = PairPointerPalette.slot(red: p[2], green: p[1], blue: p[0], alpha: p[3]) { count[slot] += 1 }
                else { other += 1 }
            }
        }
        info["opaqueBySlot"] = count
        info["nonOpaque"] = alpha
        info["opaqueOffPalette"] = other
        if alpha > 0 { return reject(.transparentMarker) }
        if other > 0 { return reject(.offPaletteMarker) }
        guard let slot = count.firstIndex(of: (x1-x0)*(y1-y0)) else { return reject(.mixedMarker) }
        return Reading(slot: slot, record: info)
    }
}

enum PairVisualEvidence {
    static func crop(frames: [CGRect], display: CGRect) -> CGRect? {
        guard frames.count == 2 else { return nil }
        // Lower editor interior avoids window chrome, the insertion point and registered text.
        let interiors = frames.map {
            CGRect(x: $0.minX + 18, y: $0.minY + $0.height * 0.52, width: $0.width - 36, height: $0.height * 0.48 - 18)
        }
        let common = interiors[0].intersection(interiors[1]).intersection(display)
        guard !common.isNull, common.width >= 16, common.height >= 16 else { return nil }
        let r = CGRect(x: floor(common.midX) - 4, y: floor(common.midY) - 4, width: 8, height: 8)
        return common.contains(r) ? r : nil
    }

    static func eligible(slot: Int, target: Int, presentation: Double, uncertainty: Double,
                         before: PairPhysicalSample, after: PairPhysicalSample) -> Bool {
        guard (0...1).contains(slot), (0...1).contains(target), (0...1).contains(before.slot), (0...1).contains(after.slot),
              uncertainty >= 0, uncertainty <= 0.005, before.from <= before.to, after.from <= after.to,
              presentation.isFinite, before.from.isFinite, after.to.isFinite,
              before.to <= presentation - uncertainty, after.from >= presentation + uncertainty else { return false }
        if before.slot == after.slot { return slot == before.slot }
        // A compositor/WindowServer notification can straddle presentation. Only a positively read
        // target color and source -> target stack transition can establish the first target frame.
        return before.slot == 1 - target && after.slot == target && slot == target
    }

    static func receipt(frames: [PairVisualFrame], target: Int, uncertainty: Double,
                        down: ClosedRange<Double>, up: ClosedRange<Double>) -> [String: Any] {
        func unknown(_ reason: PairVisualFailure) -> [String: Any] { ["status":"UNKNOWN", "reason":reason.rawValue] }
        guard down.lowerBound > 0, up.lowerBound >= down.upperBound,
              let firstTargetIndex = frames.firstIndex(where: { $0.slot == target }) else { return unknown(.noTargetPresentation) }
        let source = frames[..<firstTargetIndex], first = frames[firstTargetIndex]
        guard let last = source.last, source.contains(where: { $0.time + uncertainty < down.lowerBound }),
              source.allSatisfy({ $0.slot == 1 - target }), frames[firstTargetIndex...].allSatisfy({ $0.slot == target }),
              zip(frames, frames.dropFirst()).allSatisfy({ $0.time < $1.time && $0.ticks < $1.ticks }) else {
            return unknown(.ambiguousSurface)
        }
        guard first.time - uncertainty >= down.upperBound else { return unknown(.targetPrecededClick) }
        let earliest = max(last.time - uncertainty, down.lowerBound)
        // The independent post-presentation stack query also has a duration. Keep it in the
        // conservative visible upper bound; report the frame's actual display timestamp separately.
        let latest = max(first.time + uncertainty, first.after.to)
        func latency(_ action: ClosedRange<Double>) -> [String: Double] {
            ["lower":(earliest - action.upperBound) * 1000, "upper":(latest - action.lowerBound) * 1000]
        }
        var fromDown = latency(down)
        fromDown["lower"] = max(0, fromDown["lower"]!)
        return ["status":"OBSERVED", "sourceSlot":1 - target, "targetSlot":target,
                "lastSourceDisplayUptime":last.time, "firstTargetDisplayUptime":first.time,
                "evidenceKind":"firstObservedNativeFrame", "firstTargetPhysicalBracketSeconds":first.after.to-first.before.from,
                "firstTargetPresentationMachTicks":first.ticks, "clickDownUptime":[down.lowerBound,down.upperBound],
                "clickUpUptime":[up.lowerBound,up.upperBound], "downToVisibleMS":fromDown, "upToVisibleMS":latency(up)]
    }

    static func snapshotInterval(baseline: PairVisualFrame, source: PairVisualFrame, target: Int, measured: Int,
                                 before: PairPhysicalSample, after: PairPhysicalSample, uncertainty: Double,
                                 down: ClosedRange<Double>, up: ClosedRange<Double>) -> [String: Any]? {
        guard baseline.slot == 1-target, source.slot == baseline.slot, measured == target, before.slot == target, after.slot == target,
              (0...0.005).contains(uncertainty), baseline.time + uncertainty < down.lowerBound,
              baseline.time <= source.time, source.time + uncertainty <= before.from,
              down.upperBound <= up.lowerBound, up.upperBound <= before.from,
              before.from <= before.to, before.to <= after.from, after.from <= after.to else { return nil }
        let earliest = max(source.time - uncertainty, down.lowerBound)
        return ["status": "BOUNDED_SCREENSHOT", "evidenceKind": "windowFilteredNativeScreenshotAfterInput",
                "sourceSlot": source.slot, "targetSlot": target,
                "lastSourceDisplayUptime": source.time, "confirmedByUptime": after.to,
                "downToVisibleMS": ["lower": max(0,(earliest-down.upperBound)*1000), "upper": (after.to-down.lowerBound)*1000],
                "upToVisibleMS": ["lower": (earliest-up.upperBound)*1000, "upper": (after.to-up.lowerBound)*1000]]
    }

    static func physicalTop(rows: [[String: Any]], frames: [CGRect], numbers: [UInt32], pid: pid_t,
                            crop: CGRect, coverage: inout PairStackCoverage) throws -> Int {
        guard frames.count == 2, numbers.count == 2, numbers[0] != numbers[1], !crop.isEmpty else {
            throw PairVisualFailure.invalidBinding
        }
        func bounds(_ row: [String: Any]) -> CGRect? {
            guard let raw = row[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: raw), !rect.isNull, !rect.isInfinite,
                  rect.origin.x.isFinite, rect.origin.y.isFinite, rect.size.width.isFinite, rect.size.height.isFinite,
                  rect.size.width >= 0, rect.size.height >= 0 else { return nil }
            return rect
        }

        var top: Int?, seen = [false, false]
        // WindowServer returns this list in front-to-back order. Both exact documents must be
        // verified even after the first completely covers the common synthetic editor patch.
        for row in rows {
            if let number = row[kCGWindowNumber as String] as? UInt32, let slot = numbers.firstIndex(of: number) {
                guard !seen[slot], row[kCGWindowOwnerPID as String] as? pid_t == pid,
                      row[kCGWindowLayer as String] as? Int == 0, row[kCGWindowAlpha as String] as? Double == 1,
                      row[kCGWindowIsOnscreen as String] as? Bool == true, let rect = bounds(row),
                      rect == frames[slot], rect.insetBy(dx: 12, dy: 12).contains(crop) else {
                    throw PairVisualFailure.geometryChanged
                }
                seen[slot] = true
                coverage.enrolledRows += 1
                if top == nil { top = slot }
                continue
            }
            if top != nil {
                coverage.behindOpaque += 1
                continue
            }
            let alpha = row[kCGWindowAlpha as String] as? Double
            if alpha == 0 {
                coverage.transparentFront += 1
                continue
            }
            guard let rect = bounds(row) else {
                coverage.unknownFront += 1
                throw PairVisualFailure.foregroundCoverageUnknown
            }
            if rect.isEmpty || !rect.intersects(crop) {
                coverage.disjointFront += 1
                continue
            }
            guard let alpha, alpha > 0, alpha <= 1 else {
                coverage.unknownFront += 1
                throw PairVisualFailure.foregroundCoverageUnknown
            }
            coverage.intersectingFront += 1
            throw PairVisualFailure.foregroundIntersectsCrop
        }
        guard seen == [true, true], let top else { throw PairVisualFailure.geometryChanged }
        return top
    }
}

#if !PAIR_VISUAL_REPLAY
final class PairPointerVisual: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label:"nearpane.acceptance.pair-pointer-presentation",qos:.userInitiated)
    private let request: P2Request, numbers: [UInt32], frames: [CGRect], target: Int, displayUUID: String
    private let display: CGDirectDisplayID, displayBounds: CGRect, crop: CGRect?, clock: PreviewClock?
    private var capture: SCStream?, timer: DispatchSourceTimer?, stopped = false
    private var failure: PairVisualFailure?, stack = [PairPhysicalSample](), samples = [PairVisualFrame]()
    private var delivered = 0, idle = 0, beforeBaseline = 0, lastTicks: UInt64 = 0
    private var guardDurations = [Double](), seenTargetInStack = false
    private var stackAttempts = 0, coverage = PairStackCoverage()
    private var frameDiagnostics = [VisualRow](), startedWithoutPixels = 0, startedWithoutClock = 0
    private var lastIdleTick: UInt64?, lastIdleAnchor: UInt64?
    private var endpoint: VisualRow?, endpointPending = false
    private var displayFilter: SCContentFilter?, displayConfig: SCStreamConfiguration?

    private init(request: P2Request, numbers: [UInt32], target: UInt32, frames: [CGRect], displayUUID: String) {
        self.request = request; self.numbers = numbers; self.frames = frames; self.displayUUID = displayUUID
        self.target = numbers.firstIndex(of: target) ?? -1
        display = CGMainDisplayID(); displayBounds = CGDisplayBounds(display)
        crop = PairVisualEvidence.crop(frames: frames, display: displayBounds)
        clock = try? PreviewClock.read()
    }

    static func start(request: P2Request, numbers: [UInt32], target: UInt32,
                      frames: [CGRect], displayUUID: String) -> PairPointerVisual {
        let observer = PairPointerVisual(request: request, numbers:numbers, target:target, frames:frames, displayUUID:displayUUID)
        observer.queue.async { observer.arm() }
        observer.wait(seconds:1.6) { $0.failure != nil || !$0.samples.isEmpty }
        observer.queue.sync {
            if observer.samples.first?.slot != 1 - observer.target { observer.fail(.noSourcePresentationBeforeClick) }
        }
        return observer
    }

    // Only used before posting or after the normal independent AX focus observations finish.
    private func wait(seconds: Double, until condition: (PairPointerVisual)->Bool) {
        let end = visualNow() + seconds
        while visualNow() < end && !queue.sync(execute: { condition(self) }) {
            if !Thread.isMainThread || !RunLoop.current.run(mode:.default, before:Date(timeIntervalSinceNow:0.003)) {
                Thread.sleep(forTimeInterval:0.003)
            }
        }
    }

    private func physical() throws -> PairPhysicalSample {
        let from = visualNow()
        guard let pid = request.pid, let birth = request.birth, let hostBirth = request.hostBirth, let crop,
              request.numbers == numbers, numbers.count == 2, Set(numbers).count == 2, (0...1).contains(target),
              let expectedSpaceUUID = request.spaceUUID, frames.count == 2 else { throw PairVisualFailure.invalidBinding }
        guard request.hid == p2Physical() else { throw PairVisualFailure.userSuperseded }
        guard birthMicroseconds(pid) == birth, birthMicroseconds(request.hostPID) == hostBirth else { throw PairVisualFailure.enrollmentChanged }
        var activeCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &activeCount) == .success, activeCount == 1, CGMainDisplayID() == display,
              CGDisplayBounds(display) == displayBounds, let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue(),
              CFEqual(CFUUIDCreateString(nil,uuid), displayUUID as CFString),
              let all = NPReadInventory() as? [VisualRow], all.count == 1, let scope = all.first,
              scope["Display Identifier"] as? String == request.display,
              (scope["Current Space"] as? VisualRow)?["id64"] as? UInt64 == request.space,
              (scope["Spaces"] as? [VisualRow])?.contains(where: { $0["id64"] as? UInt64 == request.space &&
                  $0["type"] as? Int == 0 && ($0["uuid"] as? String)?.lowercased() == expectedSpaceUUID.lowercased() }) == true else {
            throw PairVisualFailure.displayOrSpaceChanged
        }
        guard let catalog = NPReadCatalogSpaceWindowNumbers(request.space) as? [UInt32],
              numbers.allSatisfy(catalog.contains), numbers.allSatisfy({ NPReadWindowSpaces($0) as? [UInt64] == [request.space] }) else {
            throw PairVisualFailure.enrollmentChanged
        }
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [VisualRow]
        else { throw PairVisualFailure.obscuredOrUncertainCrop }
        let slot = try PairVisualEvidence.physicalTop(rows: rows, frames: frames, numbers: numbers,
                                                      pid: pid, crop: crop, coverage: &coverage)
        return PairPhysicalSample(from:from, to:visualNow(), slot:slot)
    }

    private func readStack() {
        guard !stopped else { return }
        stackAttempts += 1
        do {
            let reading = try physical()
            guard !seenTargetInStack || reading.slot == target else { fail(.ambiguousSurface); return }
            if reading.slot == target { seenTargetInStack = true }
            guard guardDurations.count < 800 else { fail(.presentationUnbounded); return }
            guardDurations.append(reading.to - reading.from)
            stack.append(reading)
            if stack.count > 140 { stack.removeFirst(64) }
        } catch { fail(error as? PairVisualFailure ?? .obscuredOrUncertainCrop) }
    }

    private func arm() {
        guard clock != nil, crop != nil, CGPreflightScreenCaptureAccess() else { fail(.inaccessibleDisplay); return }
        guard let hash = request.hash, let pid = request.pid, runningCodeHash(pid) == hash,
              runningCodeHash(request.hostPID) == request.hostHash else { fail(.enrollmentChanged); return }
        readStack()
        guard !stopped, stack.last?.slot == 1 - target else { fail(.noSourcePresentationBeforeClick); return }
        let poll = DispatchSource.makeTimerSource(queue:queue)
        poll.schedule(deadline:.now(), repeating:.milliseconds(12),leeway:.milliseconds(1))
        poll.setEventHandler { [weak self] in self?.readStack() }
        timer = poll; poll.resume()
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly:true) { [weak self] content, _ in
            guard let self else { return }
            self.queue.async { self.configure(content) }
        }
    }

    private func configure(_ content: SCShareableContent?) {
        guard !stopped else { return }
        guard crop != nil, let pid = request.pid, let content, content.displays.count == 1, let screen = content.displays.first,
              screen.displayID == display, screen.frame == displayBounds else { fail(.inaccessibleDisplay); return }
        let pair = content.windows.filter { numbers.contains($0.windowID) && $0.owningApplication?.processID == pid && $0.isOnScreen }
        guard pair.count == 2, Set(pair.map(\.windowID)) == Set(numbers),
              pair.allSatisfy({ w in numbers.firstIndex(of:w.windowID).map { frames[$0] == w.frame } == true }) else {
            fail(.geometryChanged); return
        }
        let filter = SCContentFilter(display:screen, including:pair)
        filter.includeMenuBar = false
        guard Set(filter.includedWindows.map(\.windowID)) == Set(numbers),
              Set(filter.includedApplications.map(\.processID)).isSubset(of:[pid]) else { fail(.enrollmentChanged); return }
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = CGRect(origin: .zero, size: screen.frame.size)
        // Nine pixels for eight points leaves at least eight whole pixels at fractional origins.
        cfg.width = Int(ceil(screen.frame.width * 9 / 8))
        cfg.height = Int((CGFloat(cfg.width) * screen.frame.height / screen.frame.width).rounded())
        cfg.preservesAspectRatio = false; cfg.ignoreShadowsDisplay = true; cfg.showMouseClicks = false
        cfg.colorSpaceName = CGColorSpace.sRGB; cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.minimumFrameInterval = .zero; cfg.queueDepth = 3; cfg.showsCursor = false; cfg.captureMicrophone = false
        cfg.capturesAudio = false; cfg.includeChildWindows = false; cfg.shouldBeOpaque = false
        displayFilter = filter; displayConfig = cfg
        let stream = SCStream(filter:filter,configuration:cfg,delegate:self)
        do { try stream.addStreamOutput(self,type:.screen,sampleHandlerQueue:queue) } catch { fail(.displayStreamUnavailable); return }
        capture = stream
        stream.startCapture { [weak self] error in
            if error != nil { self?.queue.async { [weak self] in self?.fail(.displayStreamUnavailable) } }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in self?.fail(.streamInterrupted) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !stopped, type == .screen, let clock else { return }
        let callback = visualNow()
        let meta = (CMSampleBufferGetSampleAttachmentsArray(buffer,createIfNecessary:false) as? [[SCStreamFrameInfo: Any]])?.first
        let status = (meta?[.status] as? NSNumber).flatMap { SCFrameStatus(rawValue:$0.intValue) }
        if status == .idle {
            idle += 1
            if let ticks = (meta?[.displayTime] as? NSNumber)?.uint64Value, ticks > lastTicks, lastTicks > 0 {
                lastIdleTick = ticks; lastIdleAnchor = lastTicks
            }
            return
        }
        guard status == .complete || status == .started else { fail(.streamInterrupted); return }
        let ticks = (meta?[.displayTime] as? NSNumber)?.uint64Value
        let pts = buffer.presentationTimeStamp
        if status == .started && buffer.imageBuffer == nil { startedWithoutPixels += 1; return }
        if status == .started && ((ticks ?? 0) == 0 || !pts.isNumeric) { startedWithoutClock += 1; return }
        delivered += 1
        guard delivered <= 400 else { fail(.presentationUnbounded); return }
        var diag: VisualRow = ["callback": callback, "status": status?.rawValue as Any]
        if let ticks { diag["machTicks"] = ticks; diag["displayUptime"] = clock.mapped(ticks) }
        if pts.isNumeric { diag["ptsUptime"] = pts.seconds + clock.hostOffset }
        if let image = buffer.imageBuffer {
            diag["size"] = [CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image)]
            diag["pixelFormat"] = CVPixelBufferGetPixelFormatType(image)
        }
        frameDiagnostics.append(diag)
        let index = frameDiagnostics.count - 1
        guard buffer.isValid, let ticks, ticks > lastTicks, ticks != 0, pts.isNumeric else { fail(.nativeClockUnavailable); return }
        lastTicks = ticks
        let time = clock.mapped(ticks)
        guard PreviewClock.presentationBounds(display: time, pts: pts.seconds + clock.hostOffset, callback: callback) != nil else {
            fail(.nativeClockUnavailable); return
        }
        // Stream delivery may precede the compositor timestamp. Do not read pixels until the same
        // enrolled physical stack is checked after the calibrated presentation.
        let wait = max(0, time + clock.uncertainty - visualNow()) + 0.0001
        queue.asyncAfter(deadline:.now()+wait) { [weak self] in self?.observe(buffer,ticks:ticks,time:time,callback:callback,index:index) }
    }

    private func observe(_ buffer: CMSampleBuffer, ticks: UInt64, time: Double, callback: Double, index: Int) {
        guard !stopped, let clock, let crop else { return }
        readStack()
        guard !stopped, let after = stack.last else { return }
        guard let before = stack.last(where: { $0.to <= time - clock.uncertainty }), after.from >= time + clock.uncertainty else {
            frameDiagnostics[index]["bracket"] = "missingBeforeOrAfter"
            if samples.isEmpty { beforeBaseline += 1 } else { fail(.noBracketedPresentation) }
            return
        }
        frameDiagnostics[index]["physicalBracket"] = [before.from, before.to, after.from, after.to]
        let covered = stack.filter { $0.from >= before.from && $0.to <= after.to }.map(\.slot)
        let progress = covered.map { $0 == target ? 1 : 0 }
        guard progress == progress.sorted() else { fail(.ambiguousSurface); return }
        let read = PairFocusRaster.measure(buffer, display: displayBounds, crop: crop)
        frameDiagnostics[index]["raster"] = read.record
        guard let slot = read.slot else { fail(read.issue ?? .pixelBufferUnavailable); return }
        guard PairVisualEvidence.eligible(slot:slot,target:target,presentation:time,uncertainty:clock.uncertainty,
                                          before:before,after:after) else { fail(.ambiguousSurface); return }
        samples.append(PairVisualFrame(slot:slot,ticks:ticks,time:time,callback:callback,before:before,after:after))
    }

    // A static filtered display can emit only idle notifications after the click. One real
    // checked screenshot may bound visibility; it cannot give the first changed frame's time.
    private func captureEndpoint(down: ClosedRange<Double>, up: ClosedRange<Double>) {
        guard !stopped, !endpointPending, endpoint == nil, let clock, let crop, let filter = displayFilter, let cfg = displayConfig,
              let baseline = samples.first, let source = samples.last, source.slot == 1 - target, !samples.contains(where: { $0.slot == target }) else { return }
        readStack()
        guard !stopped, let before = stack.last, before.slot == target, before.from >= up.upperBound else {
            endpoint = ["status":"UNKNOWN", "reason":"terminalTargetStackUnconfirmed"]
            return
        }
        endpointPending = true
        SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: cfg) { [weak self] buffer, _ in
            guard let self else { return }
            self.queue.async {
                defer { self.endpointPending = false }
                guard !self.stopped else { return }
                self.readStack()
                var report: VisualRow = ["status":"UNKNOWN", "reason":"terminalImageOrPhysicalStackUnconfirmed",
                                         "requestAfterUptime":before.to]
                defer { self.endpoint = report }
                guard !self.stopped, let after = self.stack.last, after.slot == self.target,
                      let buffer, buffer.isValid else { return }
                report["completedBeforeUptime"] = after.to
                let read = PairFocusRaster.measure(buffer, display: self.displayBounds, crop: crop)
                report["raster"] = read.record
                guard let measured = read.slot else {
                    report["reason"] = (read.issue ?? .pixelBufferUnavailable).rawValue
                    return
                }
                if let interval = PairVisualEvidence.snapshotInterval(baseline: baseline, source: source, target: self.target, measured: measured,
                       before: before, after: after, uncertainty: clock.uncertainty, down: down, up: up) {
                    report.removeValue(forKey: "reason")
                    report.merge(interval) { _, rhs in rhs }
                }
            }
        }
    }

    private func stop() {
        guard !stopped else { return }
        stopped = true; timer?.cancel(); timer = nil
        capture?.stopCapture { _ in }; capture = nil
    }
    private func fail(_ issue: PairVisualFailure) {
        guard !stopped else { return }
        failure = issue; stop()
    }
    func cancel() { queue.sync { stop() } }

    func finish(events: [[String: Any]]) -> [String: Any] {
        func post(_ kind: CGEventType) -> ClosedRange<Double>? {
            let list = events.filter { ($0["type"] as? NSNumber)?.uint32Value == kind.rawValue }
            guard list.count == 1, let before = list[0]["beforePost"] as? Double, let after = list[0]["afterPost"] as? Double,
                  before.isFinite, after.isFinite, before > 0, before <= after else { return nil }
            return before...after
        }
        let down = post(.leftMouseDown), up = post(.leftMouseUp)
        if let down, let up {
            wait(seconds:0.4) { observer in observer.failure != nil || observer.samples.contains(where: { $0.slot == observer.target }) }
            queue.sync { captureEndpoint(down: down, up: up) }
            wait(seconds:0.25) { observer in
                observer.failure != nil || observer.samples.contains(where: { $0.slot == observer.target }) ||
                    (observer.endpoint != nil && !observer.endpointPending)
            }
        }
        return queue.sync {
            if endpointPending && endpoint == nil {
                endpoint = ["status":"UNKNOWN", "reason": samples.contains { $0.slot == target } ?
                    "streamTargetArrivedBeforeScreenshot" : "terminalScreenshotDeadline"]
            }
            if !stopped {
                readStack()
                if samples.contains(where:{ $0.slot == target }), stack.last?.slot != target { fail(.ambiguousSurface) }
            }
            if !stopped, let start = clock, let end = try? PreviewClock.read(), abs(end.machOffset - start.machOffset) <= 0.002,
               abs(end.hostOffset - start.hostOffset) <= 0.002, let pid = request.pid,
               runningCodeHash(pid) == request.hash, runningCodeHash(request.hostPID) == request.hostHash {
                stop()
            } else if !stopped { fail(.clockChanged) }
            var result: VisualRow = ["status":"UNKNOWN", "reason": PairVisualFailure.inputTimesUnavailable.rawValue]
            if let failure { result["reason"] = failure.rawValue }
            else if let down, let up, let clock { result = PairVisualEvidence.receipt(frames:samples,target:target,uncertainty:clock.uncertainty,down:down,up:up) }
            if failure == nil, result["reason"] as? String == PairVisualFailure.noTargetPresentation.rawValue,
               let endpoint, endpoint["status"] as? String == "BOUNDED_SCREENSHOT" {
                for key in ["status", "evidenceKind", "sourceSlot", "targetSlot", "lastSourceDisplayUptime", "confirmedByUptime",
                            "downToVisibleMS", "upToVisibleMS"] { result[key] = endpoint[key] }
                result.removeValue(forKey: "reason")
            }
            result["method"] = "twoEnrolledWindowDisplayRasterWithPhysicalStackAtEightPointCrop"
            result["displayPointBounds"] = [displayBounds.minX,displayBounds.minY,displayBounds.width,displayBounds.height]
            if let cfg = displayConfig { result["requestedRaster"] = [cfg.width,cfg.height] }
            result["fixtureWindows"] = numbers; result["spaceUUID"] = request.spaceUUID
            if let crop { result["cropPoints"] = [crop.minX,crop.minY,crop.width,crop.height] }
            result["frames"] = samples.map(\.receipt); result["completeDeliveries"] = delivered; result["idleDeliveries"] = idle
            result["unbracketedBeforeEnrollment"] = beforeBaseline; result["clockUncertaintySeconds"] = clock?.uncertainty
            result["targetFrameObserved"] = samples.contains { $0.slot == target }
            result["maxStackQueryMS"] = guardDurations.max().map { $0 * 1000 }
            result["stackQueryCount"] = guardDurations.count
            result["stackQueryAttempts"] = stackAttempts
            result["physicalStackCoverageTotals"] = coverage.receipt
            result["frameDiagnostics"] = frameDiagnostics
            result["startedWithoutPixels"] = startedWithoutPixels
            result["startedWithoutClock"] = startedWithoutClock
            result["lastIdleTicks"] = lastIdleTick
            result["lastIdleHeldCompleteTicks"] = lastIdleAnchor
            result["streamObservation"] = samples.contains { $0.slot == target } ? "targetFrameObserved" :
                (samples.isEmpty ? "noQualifiedSourceFrame" : (idle > 0 ? "sourceAndIdleOnly" : "sourceWithoutNewTarget"))
            if let endpoint { result["terminalScreenshot"] = endpoint }
            result["retainedPixelBytes"] = 0
            return result
        }
    }
}
#endif
