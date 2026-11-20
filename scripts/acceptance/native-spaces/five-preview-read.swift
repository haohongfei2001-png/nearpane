// Read only the signed Host's own AX tree, enrolled synthetic windows and numeric system membership.
func readFive(_ run: FiveRun) -> Object {
    var proof: Object = ["ready": false, "membership": false, "stageOff": stage == false,
                         "uptime": ProcessInfo.processInfo.systemUptime, "privatePixelsWritten": 0]
    func stop(_ reason: String) -> Object { proof["reason"] = reason; return proof }
    guard run.valid, let kit = PreviewCensus.kit(CommandLine.arguments[0]),
          let host, host.processIdentifier == run.hostPID, birthMicroseconds(run.hostPID) == run.hostBirth,
          runningCodeHash(run.hostPID) == run.hostHash, splitSignedPID(run.hostPID, identifier: bundleID),
          splitProcessPath(run.hostPID) == "/Applications/Nearpane.app/Contents/MacOS/NearpaneHost",
          AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else { return stop("signedHostOrObserverPermissionUnavailable") }
    guard stage == false, let scopes = spaces, scopes.count == 1, NSScreen.screens.count == 1, let scope = scopes.first,
          (scope["scope"] as? String)?.uppercased() == run.display, scope["current"] as? UInt64 == run.space,
          let records = scope["records"] as? [Object], records.filter({ $0["id"] as? UInt64 == run.space &&
              $0["type"] as? Int == 0 && $0["uuid"] as? String == run.spaceUUID }).count == 1,
          let screen = displays().first, screen["uuid"] as? String == run.display,
          let displayBounds = fiveDisplayNumbers(screen["bounds"]), let displayFrame = fiveRect(displayBounds)
    else { return stop("expectedActiveOrdinaryDisplaySpaceOrStageOffUnavailable") }
    proof["hardware"] = [CGEventType.leftMouseDown,.rightMouseDown,.otherMouseDown,.keyDown,.scrollWheel].map {
        CGEventSource.counterForEventType(.hidSystemState,eventType:$0)
    }
    for owner in run.owners {
        let path = kit.appendingPathComponent("Five Notes \(owner.slot + 1).app/Contents/MacOS/FiveNotes").path
        let app = NSRunningApplication(processIdentifier: owner.pid)
        guard birthMicroseconds(owner.pid) == owner.birth, splitProcessPath(owner.pid) == splitRealPath(path),
              runningCodeHash(owner.pid) == owner.hash, splitSignedPID(owner.pid, identifier: owner.identifier),
              app?.activationPolicy == .regular, app?.bundleIdentifier == owner.identifier,
              let registered = app?.bundleURL?.appendingPathComponent("Contents/MacOS/FiveNotes").path,
              splitRealPath(registered) == splitRealPath(path) else { return stop("fixtureGenerationOrSignatureChangedSlot\(owner.slot)") }
    }
    let census = PreviewCensus.report(run.space, host: run.hostPID, fixture: run.owners.first?.pid ?? 0,
                                      expected: run.owners.map(\.number), visible: true,
                                      enrolledOwners: Dictionary(uniqueKeysWithValues: run.owners.map { ($0.number, $0.pid) }))
    proof["census"] = census
    guard census["admitted"] as? Bool == true, let members = census["expectedEvidence"] as? [Object]
    else { return stop("activeSpaceUnenrolledOrUnverifiedWindows") }
    var sourceFrames = [[Double]](), sources = [[Double]]()
    for owner in run.owners {
        guard let member = members.first(where: { $0["number"] as? UInt32 == owner.number }),
              member["accepted"] as? Bool == true, member["publicCurrent"] as? Bool == true,
              let box = fiveDisplayNumbers(member["bounds"]), let frame = fiveRect(box), frame.width >= 96, frame.height >= 84,
              displayFrame.contains(frame) else { return stop("sourceOnPhysicalDisplayUnconfirmedSlot\(owner.slot)") }
        sourceFrames.append(box)
        sources.append([floor(frame.midX)-2, floor(frame.midY)-2, 4, 4])
    }
    proof["membership"] = true
    proof["sourceFrames"] = sourceFrames
    guard let list else { return stop("windowServerListUnavailable") }
    let index = Sidebar(host, rows: list)
    guard index.areas == 1, index.regions.count == 1, let region = pairedRect(index.regions[0]) else { return stop("installedSidebarRegionUnavailable") }
    let panels: [(UInt32,CGRect)] = list.compactMap { item in
        guard item[kCGWindowOwnerPID as String] as? pid_t == run.hostPID, item[kCGWindowIsOnscreen as String] as? Bool == true,
              item[kCGWindowLayer as String] as? Int == Int(CGWindowLevelForKey(.floatingWindow)),
              let n = item[kCGWindowNumber as String] as? UInt32, let b = item[kCGWindowBounds as String] as? NSDictionary,
              let f = CGRect(dictionaryRepresentation:b), f.contains(region.insetBy(dx:1,dy:1)) else { return nil }
        return (n,f)
    }
    guard panels.count == 1 else { return stop("installedPanelAmbiguous") }
    let (panel,panelFrame) = panels[0]
    let cards = index.controls.filter { $0.key.hasPrefix("current-desktop-window:") || $0.key.hasPrefix("native-space-window:") }
    proof["cardCount"] = cards.values.reduce(0) { $0 + $1.count }
    proof["present"] = run.owners.map { cards[$0.card]?.count == 1 }
    proof["region"] = windowReceiptRect(region)
    guard Set(cards.keys) == Set(run.owners.map(\.card)), cards.values.allSatisfy({$0.count == 1}) else { return stop("missingDuplicateOrUnenrolledCard") }
    var read = [Object](), pictures = [[Double]]()
    for owner in run.owners {
        guard let card = cards[owner.card]?.first else { return stop("cardDisappeared") }
        var row = pairedCard(card, host: run.hostPID, panel: panel, region: region, panelFrame: panelFrame, id: owner.card)
        row["slot"] = owner.slot; row["number"] = owner.number; row["pid"] = owner.pid
        read.append(row)
        if row["panelBound"] as? Bool == true, row["geometryReady"] as? Bool == true, let patch = row["patch"] as? [Double] { pictures.append(patch) }
    }
    proof["cards"] = read
    guard pictures.count == run.owners.count else { return stop("enrolledCardInteriorOutsideCurrentViewportOrUnbound") }
    let patches = pictures.compactMap(fiveRect)
    guard patches.isEmpty || (patches.count == pictures.count && patches.allSatisfy({region.contains($0) && panelFrame.contains($0) && displayFrame.contains($0)}) &&
        patches.enumerated().allSatisfy({i,patch in !patches.prefix(i).contains(where: {$0.intersects(patch)})}) &&
        patches.reduce(CGRect.null, {$0.union($1)}).width <= 12)
    else { return stop("fivePatchesDoNotFitDistinctPositionsInOneSafeColumn") }
    proof["geometry"] = ["panel":panel,"sources":sources,"pictures":pictures,"region":windowReceiptRect(region),"displayBounds":displayBounds] as Object
    proof["ready"] = true
    return proof
}
let fiveRaw = FileHandle.standardInput.readDataToEndOfFile()
let fiveResult: Object
if let run = try? JSONDecoder().decode(FiveRun.self, from:fiveRaw) {
    fiveResult = readFive(run)
} else if let request = try? JSONSerialization.jsonObject(with:fiveRaw) as? Object,
          request["operation"] as? String == "initialIdentity", let pid = request["pid"] as? pid_t, pid == host?.processIdentifier,
          let hash = request["hash"] as? String, runningCodeHash(pid) == hash, let birth = birthMicroseconds(pid),
          let expected = request["space"] as? UInt64, let scopes = spaces, scopes.count == 1, let scope = scopes.first,
          scope["current"] as? UInt64 == expected, let display = scope["scope"] as? String, let records = scope["records"] as? [Object],
          let active = records.first(where: { $0["id"] as? UInt64 == expected && $0["type"] as? Int == 0 }),
          let uuid = active["uuid"] as? String {
    fiveResult = ["ready":true,"hostPID":pid,"hostBirth":birth,"hostHash":hash,"display":display.uppercased(),"space":expected,"spaceUUID":uuid,"owners":[]]
} else { fiveResult = ["ready":false,"reason":"invalidEnrolmentOrUnexpectedActiveSpace"] }
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:fiveResult,options:[.sortedKeys]) + Data([10]))
