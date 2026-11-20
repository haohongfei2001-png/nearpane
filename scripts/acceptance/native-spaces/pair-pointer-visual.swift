import AppKit
import ScreenCaptureKit

private typealias VisualRow = [String: Any]
private func visualNow() -> Double { ProcessInfo.processInfo.systemUptime }

enum PairVisualFailure: String, Error {
    case invalidBinding, inaccessibleDisplay, displayOrSpaceChanged, enrollmentChanged, userSuperseded
    case otherOrdinaryWindow, obscuredOrUncertainCrop, geometryChanged, displayStreamUnavailable
    case noSourcePresentationBeforeClick, streamInterrupted, clockChanged, presentationUnbounded
    case missingOpaqueMarker, ambiguousSurface, noTargetPresentation, inputTimesUnavailable, targetPrecededClick
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
              before.to <= presentation - uncertainty, after.from >= presentation + uncertainty,
              after.to - before.from <= 0.050 else { return false }
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
                "firstTargetPresentationMachTicks":first.ticks, "clickDownUptime":[down.lowerBound,down.upperBound],
                "clickUpUptime":[up.lowerBound,up.upperBound], "downToVisibleMS":fromDown, "upToVisibleMS":latency(up)]
    }

    static func physicalTop(rows: [[String:Any]], frames: [CGRect], numbers: [UInt32], pid: pid_t, crop: CGRect) throws -> Int {
        guard frames.count == 2, numbers.count == 2 else { throw PairVisualFailure.invalidBinding }
        var top: Int?, matches = [0, 0]
        for row in rows {
            guard let raw = row[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: raw), !rect.isInfinite else { throw PairVisualFailure.obscuredOrUncertainCrop }
            guard rect.intersects(crop) else { continue }
            guard let opacity = row[kCGWindowAlpha as String] as? Double else { throw PairVisualFailure.obscuredOrUncertainCrop }
            if opacity == 0 { continue }
            guard let owner = row[kCGWindowOwnerPID as String] as? pid_t, let number = row[kCGWindowNumber as String] as? UInt32,
                  let layer = row[kCGWindowLayer as String] as? Int else { throw PairVisualFailure.obscuredOrUncertainCrop }
            if owner == pid, let slot = numbers.firstIndex(of: number) {
                guard layer == 0, opacity == 1, row[kCGWindowIsOnscreen as String] as? Bool == true,
                      frames[slot] == rect, rect.insetBy(dx: 12, dy: 12).contains(crop) else { throw PairVisualFailure.geometryChanged }
                matches[slot] += 1
                if top == nil { top = slot }
            } else if top == nil {
                throw PairVisualFailure.obscuredOrUncertainCrop
            }
        }
        guard matches == [1,1], let top else { throw PairVisualFailure.geometryChanged }
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
              Set(numbers).isSubset(of: Set(catalog)), numbers.allSatisfy({ NPReadWindowSpaces($0) as? [UInt64] == [request.space] }) else {
            throw PairVisualFailure.enrollmentChanged
        }
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [VisualRow]
        else { throw PairVisualFailure.obscuredOrUncertainCrop }
        for row in rows where row[kCGWindowLayer as String] as? Int == 0 {
            guard let owner = row[kCGWindowOwnerPID as String] as? pid_t, let number = row[kCGWindowNumber as String] as? UInt32 else {
                throw PairVisualFailure.otherOrdinaryWindow
            }
            if owner != request.hostPID && (owner != pid || !numbers.contains(number)) {
                guard !catalog.contains(number), let membership = NPReadWindowSpaces(number) as? [UInt64],
                      !membership.isEmpty, !membership.contains(request.space) else { throw PairVisualFailure.otherOrdinaryWindow }
            }
        }
        let slot = try PairVisualEvidence.physicalTop(rows:rows, frames:frames, numbers:numbers, pid:pid, crop:crop)
        return PairPhysicalSample(from:from, to:visualNow(), slot:slot)
    }

    private func readStack() {
        guard !stopped else { return }
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
        guard let crop, let pid = request.pid, let content, content.displays.count == 1, let screen = content.displays.first,
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
        cfg.sourceRect = crop.offsetBy(dx:-screen.frame.minX, dy:-screen.frame.minY)
        cfg.width = 8; cfg.height = 8; cfg.colorSpaceName = CGColorSpace.sRGB; cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.minimumFrameInterval = .zero; cfg.queueDepth = 3; cfg.showsCursor = false; cfg.captureMicrophone = false
        cfg.capturesAudio = false; cfg.includeChildWindows = false; cfg.shouldBeOpaque = false
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
        guard status == .complete || status == .started else {
            if status == .idle { idle += 1 } else { fail(.streamInterrupted) }
            return
        }
        delivered += 1
        guard delivered <= 400, buffer.isValid, let ticks = (meta?[.displayTime] as? NSNumber)?.uint64Value,
              ticks > lastTicks, ticks != 0 else { fail(.presentationUnbounded); return }
        lastTicks = ticks
        let time = clock.mapped(ticks), pts = CMTimeGetSeconds(buffer.presentationTimeStamp) + clock.hostOffset
        guard PreviewClock.presentationBounds(display:time,pts:pts,callback:callback) != nil,
              time >= callback - 0.050 else { fail(.presentationUnbounded); return }
        let wait = max(0,time + clock.uncertainty - visualNow()) + 0.0001
        queue.asyncAfter(deadline:.now()+wait) { [weak self] in self?.observe(buffer,ticks:ticks,time:time,callback:callback) }
    }

    private func observe(_ buffer: CMSampleBuffer, ticks: UInt64, time: Double, callback: Double) {
        guard !stopped, let clock else { return }
        readStack()
        guard !stopped, let after = stack.last, let before = stack.last(where: { $0.to <= time - clock.uncertainty }) else {
            if samples.isEmpty { beforeBaseline += 1 } else { fail(.presentationUnbounded) }
            return
        }
        let covered = stack.filter { $0.from >= before.from && $0.to <= after.to }.map(\.slot)
        let progress = covered.map { $0 == target ? 1 : 0 }
        guard progress == progress.sorted(), after.from >= time + clock.uncertainty, after.to - before.from <= 0.050 else {
            if samples.isEmpty, before.slot == 1 - target, after.slot == 1 - target { beforeBaseline += 1; return }
            fail(.presentationUnbounded); return
        }
        guard let image = buffer.imageBuffer, CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(image) == 8, CVPixelBufferGetHeight(image) == 8,
              CVPixelBufferLockBaseAddress(image,.readOnly) == kCVReturnSuccess else { fail(.missingOpaqueMarker); return }
        defer { CVPixelBufferUnlockBaseAddress(image,.readOnly) }
        guard let ptr = CVPixelBufferGetBaseAddress(image)?.assumingMemoryBound(to:UInt8.self),
              let slot = PairPointerPalette.slot(bgra:ptr,stride:CVPixelBufferGetBytesPerRow(image),side:8) else {
            fail(.missingOpaqueMarker); return
        }
        guard PairVisualEvidence.eligible(slot:slot,target:target,presentation:time,uncertainty:clock.uncertainty,
                                          before:before,after:after) else { fail(.ambiguousSurface); return }
        samples.append(PairVisualFrame(slot:slot,ticks:ticks,time:time,callback:callback,before:before,after:after))
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
        if down != nil, up != nil { wait(seconds:0.65) { observer in observer.failure != nil || observer.samples.contains(where: { $0.slot == observer.target }) } }
        return queue.sync {
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
            result["method"] = "twoEnrolledWindowDisplayCropWithIndependentVisibleWindowServerStack"
            result["fixtureWindows"] = numbers; result["spaceUUID"] = request.spaceUUID
            if let crop { result["cropPoints"] = [crop.minX,crop.minY,crop.width,crop.height] }
            result["frames"] = samples.map(\.receipt); result["completeDeliveries"] = delivered; result["idleDeliveries"] = idle
            result["unbracketedBeforeEnrollment"] = beforeBaseline; result["clockUncertaintySeconds"] = clock?.uncertainty
            result["targetFrameObserved"] = samples.contains { $0.slot == target }
            result["maxStackQueryMS"] = guardDurations.max().map { $0 * 1000 }
            result["stackQueryCount"] = guardDurations.count
            result["retainedPixelBytes"] = 0
            return result
        }
    }
}
#endif
