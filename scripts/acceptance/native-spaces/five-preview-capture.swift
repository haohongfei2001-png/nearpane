// The one display-filtered Host image is a narrow column confined to the proven roster
// of five synthetic cards. Only five disjoint 4x4-point patches are classified in memory.
// Source IOSurfaces belong to separately enrolled synthetic apps. No image is written.
@main struct FiveCapture {
    static func main() async {
        do { try await measure() }
        catch { try? emit(FiveRefusal(ready:false, reason:(error as? Refusal)?.reason ?? "sampleServiceUnavailable")) }
    }

    static func bound(_ run: FiveRun, kit: URL) throws -> ([String:Any], FiveGeometry) {
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = kit.appendingPathComponent("five-scope")
        child.arguments = ["compare-roster"]
        child.standardInput = input; child.standardOutput = output
        try child.run()
        input.fileHandleForWriting.write(try JSONEncoder().encode(run))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        guard child.terminationStatus == 0, let proof = try JSONSerialization.jsonObject(with:data) as? [String:Any] else {
            throw Refusal("signedObserverUnavailable")
        }
        guard proof["ready"] as? Bool == true, let value = proof["geometry"] as? [String:Any],
              let geometry = try? JSONDecoder().decode(FiveGeometry.self, from: JSONSerialization.data(withJSONObject:value)),
              geometry.sources.count == 5, geometry.pictures.count == 5, geometry.panel > 0 else {
            throw Refusal(proof["reason"] as? String ?? "incompleteScope")
        }
        return (proof,geometry)
    }

    static func noCover(_ run: FiveRun, crops: [Crop], hardwareSnapshot: [UInt32]) throws {
        guard hardware() == hardwareSnapshot, NSEvent.pressedMouseButtons == 0, birth(run.hostPID) == run.hostBirth,
              run.owners.allSatisfy({ birth($0.pid) == $0.birth }),
              let scopes = NPReadInventory() as? [[String:Any]], scopes.count == 1, let scope = scopes.first,
              (scope["Display Identifier"] as? String)?.uppercased() == run.display,
              let current = scope["Current Space"] as? [String:Any], current["id64"] as? UInt64 == run.space,
              let records = scope["Spaces"] as? [[String:Any]], records.filter({ $0["id64"] as? UInt64 == run.space && ($0["uuid"] as? String)?.uppercased() == run.spaceUUID && $0["type"] as? Int == 0 }).count == 1,
              let forward = NPReadCatalogSpaceWindowNumbers(run.space) as? [UInt32],
              run.owners.allSatisfy({ forward.contains($0.number) && NPReadWindowSpaces($0.number) as? [UInt64] == [run.space] }),
              let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements], kCGNullWindowID) as? [[String:Any]]
        else { throw Refusal("inputOrEnrolledGenerationOrSpaceChanged") }
        for (i,crop) in crops.enumerated() {
            var found = false
            for row in rows {
                guard let raw = row[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation:raw) else { throw Refusal("unreadableZOrderBounds") }
                if row[kCGWindowNumber as String] as? UInt32 == crop.number {
                    found = row[kCGWindowOwnerPID as String] as? Int32 == crop.pid && rect.contains(crop.rect) && (!crop.independentSource || crop.backing == rect)
                    break
                }
                guard (row[kCGWindowAlpha as String] as? Double ?? 1) > 0, crop.patches.contains(where:{rect.intersects($0)}) else { continue }
                if intrinsicSourceAllowsCover(isSource:i < 5, independent:crop.independentSource,
                                              ownerIsInstalledHost:row[kCGWindowOwnerPID as String] as? Int32 == run.hostPID,
                                              layer:row[kCGWindowLayer as String] as? Int, isSidebar:row[kCGWindowNumber as String] as? UInt32 == crops.last?.number) { continue }
                throw Refusal(i == 5 ? "installedPanelPatchOccluded" : "sourcePatchOccludedSlot\(i)")
            }
            if !found { throw Refusal("enrolledWindowBoundsChanged") }
        }
    }

    static func measure() async throws {
        let run = try JSONDecoder().decode(FiveRun.self, from: FileHandle.standardInput.readDataToEndOfFile())
        guard run.valid, run.owners.count == 5, NPReadOnlySpacesOpen() == 1, CGPreflightScreenCaptureAccess(), let kit = PreviewCensus.kit(CommandLine.arguments[0]) else { throw Refusal("invalidFiveOwnerEnrolment") }
        let (before,g) = try bound(run,kit:kit)
        let input = hardware()
        guard before["hardware"] as? [UInt32] == input else { throw Refusal("hardwareChangedBeforeSample") }
        let content = try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:true)
        let displays = content.displays.filter {
            CGDisplayCreateUUIDFromDisplayID($0.displayID).map { CFUUIDCreateString(nil,$0.takeRetainedValue()) as String } == run.display
        }
        guard displays.count == 1, let display = displays.first, fiveRect(g.displayBounds) == display.frame, let region = fiveRect(g.region)
        else { throw Refusal("displayIdentityOrFrameChanged") }
        let groups = zip(run.owners,g.sources).map { ($0.0.number,$0.0.pid,[$0.1],true) } + [(g.panel,run.hostPID,g.pictures,false)]
        var crops = [Crop]()
        for (id,pid,raw,isSource) in groups {
            let windows = content.windows.filter { $0.windowID == id && $0.owningApplication?.processID == pid && $0.isOnScreen }
            let patches = raw.compactMap(fiveRect)
            guard windows.count == 1, let window = windows.first, patches.count == raw.count,
                  patches.allSatisfy({ $0.size == CGSize(width:4,height:4) && $0.integral == $0 }) else { throw Refusal("windowOrPatchUnavailable") }
            let roi = patches.reduce(CGRect.null,{$0.union($1)})
            guard display.frame.contains(roi), window.frame.contains(roi),
                  isSource || (region.contains(roi) && roi.width <= 12 && roi.height <= 1400)
            else { throw Refusal("unboundedPanelOrSourceCrop") }
            let isolated = isSource ? SCContentFilter(desktopIndependentWindow:window) : nil
            let intrinsic = isolated?.pointPixelScale == 2
            let filter = intrinsic ? isolated! : SCContentFilter(display:display,including:[window])
            filter.includeMenuBar = false
            guard filter.includedWindows.count == 1, filter.includedWindows.first?.windowID == id,
                  filter.includedWindows.first?.owningApplication?.processID == pid,
                  !intrinsic || (filter.style == .window && filter.contentRect.size == window.frame.size)
            else { throw Refusal("contentFilterIdentityMismatch") }
            let backing = intrinsic ? window.frame : roi
            guard backing.width <= 1024, backing.height <= 1400, backing.contains(roi),
                  [backing.width*2,backing.height*2,(roi.minX-backing.minX)*2,(roi.minY-backing.minY)*2].allSatisfy({ $0.rounded() == $0 })
            else { throw Refusal("unregisteredBackingPixelGrid") }
            let config = SCStreamConfiguration()
            if intrinsic {
                config.ignoreShadowsSingleWindow = true; config.ignoreGlobalClipSingleWindow = true; config.shouldBeOpaque = true
            } else {
                config.sourceRect = roi.offsetBy(dx:-display.frame.minX,dy:-display.frame.minY)
            }
            config.width = Int(backing.width*2); config.height = Int(backing.height*2); config.pixelFormat = kCVPixelFormatType_32BGRA
            config.colorSpaceName = CGColorSpace.sRGB
            config.showsCursor = false; config.capturesAudio = false; config.captureMicrophone = false; config.includeChildWindows = false
            crops.append(Crop(number:id,pid:pid,rect:roi,backing:backing,independentSource:intrinsic,patches:patches,filter:filter,config:config))
        }
        try noCover(run,crops:crops,hardwareSnapshot:input)
        var observations = [[Observation]](repeating:[],count:6)
        await withTaskGroup(of:(Int,[Observation]).self) { group in
            for (i,crop) in crops.enumerated() { group.addTask { (i,await observe(crop,witness:false)) } }
            for await (i,samples) in group { observations[i] = samples }
        }
        try noCover(run,crops:crops,hardwareSnapshot:input)
        let (after,g2) = try bound(run,kit:kit)
        guard g == g2, after["hardware"] as? [UInt32] == input, hardware() == input else { throw Refusal("cardGeometryOrInputChangedDuringSample") }
        let kinds = { (proof: [String:Any]) -> [String] in
            (proof["cards"] as? [[String:Any]] ?? []).map { ($0["axValue"] as? [String:Any])?["kind"] as? String ?? "unreported" }
        }
        guard observations.prefix(5).allSatisfy({$0.count == 1}), observations[5].count == 5 else { throw Refusal("incompleteSourceOrPanelBuffer") }
        let result = FiveBatch(ready:true, before:before["uptime"] as? Double, after:after["uptime"] as? Double,
                               hardware:input, run:run, geometry:g, sources:observations.prefix(5).compactMap(\.first), cards:observations[5],
                               kindsBefore:kinds(before),kindsAfter:kinds(after),onePanelSampleBuffer:true,
                               sourceModes:crops.prefix(5).map {$0.independentSource ? "registeredSyntheticIOSurface":"visibleDisplay"},savedPixels:0)
        try emit(result)
    }
}

private struct FiveBatch: Encodable {
    let ready: Bool, before: Double?, after: Double?, hardware: [UInt32], run: FiveRun, geometry: FiveGeometry
    let sources, cards: [Observation], kindsBefore, kindsAfter: [String], onePanelSampleBuffer: Bool, sourceModes: [String], savedPixels: Int
}

private struct FiveRefusal: Encodable { let ready: Bool, reason: String }
