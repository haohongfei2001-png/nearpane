import Foundation
import CoreGraphics
import CoreVideo

@main
struct PairPointerVisualChecks {
    static func main() throws {
        var passed = [String]()
        func check(_ test: String, _ predicate: @autoclosure () -> Bool) {
            guard predicate() else { fatalError(test) }
            passed.append(test)
        }
        let display = CGRect(x:0,y:0,width:1470,height:956)
        let a = CGRect(x:555,y:392,width:320,height:193), b = CGRect(x:585,y:367,width:320,height:193)
        guard let crop = PairVisualEvidence.crop(frames:[a,b],display:display) else { fatalError("recorded fixture crop") }
        check("recordedFixtureFramesHaveInteriorOverlap", a.contains(crop) && b.contains(crop) && crop.size == CGSize(width:8,height:8))
        check("noOverlapDoesNotRead", PairVisualEvidence.crop(frames:[a,b.offsetBy(dx:400,dy:0)],display:display) == nil)
        check("titlebarOnlyDoesNotRead", PairVisualEvidence.crop(frames:[a,a.offsetBy(dx:0,dy:179)],display:display) == nil)

        func row(_ n:UInt32,_ pid:pid_t,_ frame:CGRect,_ alpha:Double = 1,_ layer:Int = 0)->[String:Any] {
            [kCGWindowNumber as String:n,kCGWindowOwnerPID as String:pid,kCGWindowLayer as String:layer,
             kCGWindowIsOnscreen as String:true,kCGWindowAlpha as String:alpha,kCGWindowBounds as String:frame.dictionaryRepresentation]
        }
        let first=row(21,42,a), second=row(22,42,b)
        func inspect(_ rows: [[String: Any]]) -> (slot: Int?, reason: PairVisualFailure?, coverage: PairStackCoverage) {
            var coverage = PairStackCoverage()
            do {
                let slot = try PairVisualEvidence.physicalTop(rows: rows, frames: [a, b], numbers: [21, 22],
                                                              pid: 42, crop: crop, coverage: &coverage)
                return (slot, nil, coverage)
            } catch {
                return (nil, error as? PairVisualFailure, coverage)
            }
        }
        func top(_ rows: [[String: Any]]) -> Int? { inspect(rows).slot }
        check("frontA", top([first,second]) == 0)
        check("frontB", top([second,first]) == 1)
        check("foreignOverlayStops", top([row(9,77,crop,0.2,12),first,second]) == nil)
        check("unknownOwnerStops", top([[kCGWindowBounds as String:crop.dictionaryRepresentation],first,second]) == nil)
        check("newGenerationSharingNumberStops", top([row(21,91,a),second]) == nil)
        check("translucentFixtureStops", top([row(21,42,a,0.7),second]) == nil)
        check("changedSiblingGeometryStops", top([first,row(22,42,b.offsetBy(dx:1,dy:0))]) == nil)
        check("missingSiblingStops", top([first]) == nil)
        check("duplicateWindowStops", top([first,first,second]) == nil)

        let outside = crop.offsetBy(dx: crop.width + 4, dy: 0)
        let corner = CGRect(x: crop.maxX - 0.25, y: crop.maxY - 0.25, width: 2, height: 2)
        let foreign = row(90, 77, crop), disjoint = row(91, 77, outside)
        let clear = row(92, 77, crop, 0)
        let noBounds = [kCGWindowNumber as String: UInt32(93)]
        let noAlpha = [kCGWindowBounds as String: crop.dictionaryRepresentation]
        let outsideOnly = [kCGWindowBounds as String: outside.dictionaryRepresentation]
        let finiteStack = inspect([disjoint, clear, first, foreign, noBounds, second])
        check("foreignOrdinaryInFrontDisjointAccepted", finiteStack.slot == 0 && finiteStack.coverage.disjointFront == 1)
        check("transparentForegroundCannotObscureCrop", finiteStack.coverage.transparentFront == 1)
        check("opaqueDocumentHidesIntersectingAndUnknownBackground", finiteStack.coverage.behindOpaque == 2)
        check("bothEnrolledDocumentsStillVerified", finiteStack.coverage.enrolledRows == 2)
        check("disjointForegroundNeedsNoForeignIdentityOrAlpha", inspect([outsideOnly, second, first]).slot == 1)
        check("ownUnenrolledWindowInFrontRefused", inspect([row(23,42,crop),second,first]).reason == .foregroundIntersectsCrop)
        check("opaqueFrontLayerZeroIntersects", inspect([foreign,first,second]).reason == .foregroundIntersectsCrop)
        let clipped = inspect([row(9,77,corner,0.01,12),first,second])
        check("partialForegroundCoverageRefused", clipped.reason == .foregroundIntersectsCrop && clipped.coverage.intersectingFront == 1)
        check("unknownForegroundBoundsRefused", inspect([noBounds, first, second]).reason == .foregroundCoverageUnknown)
        check("unknownForegroundAlphaRefused", inspect([noAlpha, first, second]).reason == .foregroundCoverageUnknown)
        check("invalidOpacityRefused", inspect([row(95,77,crop,-1),first,second]).reason == .foregroundCoverageUnknown)
        check("unknownForegroundCounted", inspect([noBounds, first, second]).coverage.unknownFront == 1)
        check("missingEnrolledOwnerBehindOpaqueRefused", inspect([first,row(22,77,b)]).reason == .geometryChanged)
        check("translucentSiblingBehindOpaqueRefused", inspect([first,row(22,42,b,0.9)]).reason == .geometryChanged)
        check("duplicateEnrolledCGIDBehindOpaqueRefused", inspect([first,second,row(21,77,a)]).reason == .geometryChanged)
        check("overlayMovesInFrontOfKnownSurfaceRefused", top([second,foreign,first]) == 1 && top([foreign,second,first]) == nil)

        func patch(_ bgra:[UInt8])->[UInt8] { Array(repeating:bgra,count:64).flatMap{$0} }
        func slot(_ bytes:[UInt8])->Int? { bytes.withUnsafeBufferPointer { PairPointerPalette.slot(bgra:$0.baseAddress!,stride:32,side:8) } }
        let blue=patch([204,123,45,255]), orange=patch([53,139,227,255])
        check("all64A", slot(blue) == 0);check("all64B", slot(orange) == 1)
        var bad=blue;bad[255]=254
        check("oneTranslucentPixel", slot(bad) == nil)
        bad=orange;bad[85]=160
        check("oneOffPalettePixel", slot(bad) == nil)
        check("blankIsNotTarget", slot(patch([0,0,0,255])) == nil)
        // Padding, Retina scaling and origin translation use the same whole-display transform as the film.
        func buffer(_ width: Int, _ height: Int, _ type: OSType = kCVPixelFormatType_32BGRA) -> CVPixelBuffer {
            var out: CVPixelBuffer?
            precondition(CVPixelBufferCreate(nil, width, height, type, nil, &out) == kCVReturnSuccess)
            return out!
        }
        let signedTile = buffer(140, 116)
        let aperture = CGRect(x: 4, y: 2, width: 128, height: 112)
        let offsetDisplay = CGRect(x: -42, y: 11, width: 64, height: 56)
        let patchRect = CGRect(x: -18, y: 31, width: 8, height: 8)
        func paint(_ x: Int, _ y: Int, _ p: [UInt8]) {
            precondition(CVPixelBufferLockBaseAddress(signedTile, []) == kCVReturnSuccess)
            let base = CVPixelBufferGetBaseAddress(signedTile)!.assumingMemoryBound(to: UInt8.self)
            let dst = base + y * CVPixelBufferGetBytesPerRow(signedTile) + x * 4
            for i in 0..<4 { dst[i] = p[i] }
            CVPixelBufferUnlockBaseAddress(signedTile, [])
        }
        // Every byte outside this exact controlled ROI is unrelated zero-initialized data.
        for y in 42..<58 { for x in 52..<68 { paint(x,y,[204,123,45,255]) } }
        func measured() -> PairFocusRaster.Reading { PairFocusRaster.measure(signedTile,display:offsetDisplay,crop:patchRect,clean:aperture) }
        let measuredA = measured()
        check("realBufferScaleAndCleanAperture", measuredA.slot == 0 && measuredA.record["pixelRect"] as? [Int] == [52,42,16,16])
        check("onlyMappedPixelsCounted", measuredA.record["opaqueBySlot"] as? [Int] == [256,0])
        paint(52,42,[204,123,45,22])
        check("transparentDistinguished", measured().issue == .transparentMarker && measured().record["nonOpaque"] as? Int == 1)
        paint(52,42,[0,0,0,255])
        check("offPaletteDistinguished", measured().issue == .offPaletteMarker && measured().record["opaqueOffPalette"] as? Int == 1)
        paint(52,42,[53,139,227,255])
        check("mixedOwnedColorsDistinguished", measured().issue == .mixedMarker && measured().record["opaqueBySlot"] as? [Int] == [255,1])
        check("unmappedAspectRefused", PairFocusRaster.measure(signedTile,display:offsetDisplay,crop:patchRect,clean:CGRect(x:0,y:0,width:110,height:50)).issue == .invalidRasterGeometry)
        check("nativeAcceptanceRequiresAtLeast64RealPixels", PairFocusRaster.measure(signedTile,display:offsetDisplay,crop:patchRect,clean:CGRect(x:0,y:0,width:32,height:28)).issue == .insufficientROISamples)
        check("unsupportedFormatDistinct", PairFocusRaster.measure(buffer(32,28,kCVPixelFormatType_32ARGB),display:offsetDisplay,crop:patchRect,clean:aperture).issue == .wrongPixelFormat)

        func sample(_ s:Int,_ a:Double,_ b:Double)->PairPhysicalSample { .init(from:a,to:b,slot:s) }
        let source=sample(0,1,1.003), destination=sample(1,1.020,1.024)
        func eligible(_ s:Int,_ b:PairPhysicalSample,_ a:PairPhysicalSample)->Bool {
            PairVisualEvidence.eligible(slot:s,target:1,presentation:1.014,uncertainty:0.0002,before:b,after:a)
        }
        check("authenticatedForwardHandoff", eligible(1,source,destination))
        check("stableTargetRequiresTargetPixels", !eligible(0,sample(1,1,1.002),destination))
        check("reverseHandoffRefused", !eligible(0,sample(1,1,1.002),sample(0,1.020,1.024)))
        check("noBracketingReadRefused", !eligible(1,source,sample(1,1.010,1.012)))
        check("broadOrderedBracketRetainsItsUncertainty", eligible(1,source,sample(1,1.070,1.074)))
        check("broadBracketWithoutSourcePixelsRefused", !eligible(0,source,sample(1,1.070,1.074)))
        func frame(_ s:Int,_ t:Double,_ n:UInt64)->PairVisualFrame {
            .init(slot:s,ticks:n,time:t,callback:t+0.001,before:sample(s,t-0.010,t-0.006),after:sample(s,t+0.005,t+0.009))
        }
        let old=frame(0,1.0,1),holding=frame(0,1.052,2),new=frame(1,1.08,3)
        func receipt(_ samples:[PairVisualFrame])->[String:Any] {
            PairVisualEvidence.receipt(frames:samples,target:1,uncertainty:0.0002,down:1.03...1.031,up:1.065...1.066)
        }
        let r=receipt([old,holding,new])
        let d=r["downToVisibleMS"] as? [String:Double], u=r["upToVisibleMS"] as? [String:Double]
        check("independentDisplayRange", r["status"] as? String == "OBSERVED" && abs((d?["lower"] ?? 999) - 20.8) < 0.0001 && abs((d?["upper"] ?? 999) - 59) < 0.0001)
        check("doesNotClampPossiblePreMouseUpPresentation", abs((u?["lower"] ?? 999) + 14.2) < 0.0001)
        check("noTargetNotAXSuccess", receipt([old,holding])["status"] as? String == "UNKNOWN")
        check("targetBeforeClickUnknown", receipt([old,frame(1,1.018,2)])["status"] as? String == "UNKNOWN")
        check("noSourceBaselineUnknown", receipt([new])["status"] as? String == "UNKNOWN")
        check("lateYankUnknown", receipt([old,new,frame(0,1.092,4)])["status"] as? String == "UNKNOWN")
        check("duplicatePresentationNotNewTarget", receipt([old,frame(1,1.08,1)])["status"] as? String == "UNKNOWN")
        check("earlyFrameClockMustAgree", PreviewClock.presentationBounds(display:1.005,pts:1.050,callback:1.001) == nil)
        check("earlyFrameWithMatchedClocksBounded", PreviewClock.presentationBounds(display:1.005,pts:1.005,callback:1.001) != nil)
        let terminal = sample(1,1.26,1.28)
        func snapshot(_ measuredSlot: Int, _ before: PairPhysicalSample) -> [String: Any]? {
            PairVisualEvidence.snapshotInterval(baseline: old, source: holding, target:1, measured:measuredSlot,
                before:before, after:terminal, uncertainty:0.0002, down:1.03...1.031, up:1.065...1.066)
        }
        let endpoint = snapshot(1, sample(1,1.20,1.203))
        check("stampedSourcePlusActualTerminalImageBoundsOnly", endpoint?["status"] as? String == "BOUNDED_SCREENSHOT" &&
              endpoint?["firstTargetPresentationMachTicks"] == nil && endpoint?["firstTargetDisplayUptime"] == nil)
        check("terminalBoundsPreserveFullObservedInterval", ((endpoint?["downToVisibleMS"] as? [String:Double])?["upper"] ?? -1) >= 249.9)
        check("terminalStackCannotSubstituteForWrongPicture", snapshot(0,sample(1,1.20,1.203)) == nil)
        check("terminalScreenshotRequiresBothPhysicalReadbacks", snapshot(1,sample(0,1.20,1.203)) == nil)
        let data=try JSONSerialization.data(withJSONObject:["status":"PASS","mode":"offline","checks":passed],options:[.sortedKeys])
        print(String(decoding:data,as:UTF8.self))
    }
}
