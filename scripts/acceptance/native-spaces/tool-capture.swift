// Crop only the two-colour area of a window owned by this process using Nearpane's production tray.
import AppKit
import ApplicationServices
import CryptoKit

@MainActor private func query(_ ctx: ToolContext, _ sql: String) throws -> [[String:Any]] {
    let file=ctx.generation.appendingPathComponent("Riftlet/queue.sqlite")
    let result=try ToolUI.run("/usr/bin/sqlite3",["-readonly","-json",file.path,sql])
    if result.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {return []}
    guard let rows=try JSONSerialization.jsonObject(with:Data(result.utf8)) as? [[String:Any]] else {
        throw ToolRefusal("The isolated screenshot library could not be observed")
    }
    return rows
}

@MainActor private func topOwner(_ point: CGPoint, excluding: Set<CGWindowID>) -> (pid_t,CGWindowID)? {
    let windows=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
    for row in windows {
        guard let id=row[kCGWindowNumber as String] as? CGWindowID, !excluding.contains(id),
              let pid=row[kCGWindowOwnerPID as String] as? pid_t,
              (row[kCGWindowAlpha as String] as? Double ?? 0) > 0,
              let b=row[kCGWindowBounds as String] as? NSDictionary,
              let r=CGRect(dictionaryRepresentation:b), r.contains(point) else {continue}
        return (pid,id)
    }
    return nil
}

@MainActor private func obstruction(to owner: CGWindowID, region: CGRect, host:pid_t, fixture:pid_t?, excluding: Set<CGWindowID> = []) -> [String:Any]? {
    let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
    for entry in entries {
        guard let id = entry[kCGWindowNumber as String] as? CGWindowID, !excluding.contains(id),
              (entry[kCGWindowAlpha as String] as? Double ?? 0) > 0,
              let value = entry[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation:value), bounds.intersects(region) else { continue }
        if id==owner && bounds.contains(region) { return nil }
        let pid=entry[kCGWindowOwnerPID as String] as? pid_t
        let system:Set<String>=["Window Server","WindowManager","Dock","Control Center","Notification Center","SystemUIServer"]
        let name=entry[kCGWindowOwnerName as String] as? String ?? ""
        let applicationID=pid.flatMap(NSRunningApplication.init(processIdentifier:))?.bundleIdentifier
        let group = fixture != nil && pid==fixture ? "fixture" : pid==host ? "Nearpane" : applicationID=="com.apple.screencaptureui" ? "Apple Screenshot" : system.contains(name) ? name : "other"
        return ["ownerClass":group,"level":entry[kCGWindowLayer as String] as? Int ?? -1,
                "overlap":NSStringFromRect(bounds.intersection(region)),"requested":NSStringFromRect(region)]
    }
    return ["ownerClass":"no visible frame","requested":NSStringFromRect(region)]
}

private func digest(_ bytes: Data) -> String {
    SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined()
}

@MainActor private func candidateDigest(_ ctx: ToolContext) throws -> String {
    guard let executable = ctx.host.executableURL else { throw ToolRefusal("No executable identity for the installed Host") }
    return try digest(Data(contentsOf:executable,options:.mappedIfSafe))
}

private func matchesPattern(_ bitmap: NSBitmapImageRep) -> Bool {
    let mid = bitmap.pixelsWide / 2
    for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
            guard let c = bitmap.colorAt(x:x,y:y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.98 else { return false }
            let blue = c.blueComponent > 0.72 && c.redComponent < 0.25 && (0.19...0.5).contains(c.greenComponent)
            let red = c.redComponent > 0.7 && c.blueComponent < 0.28 && (0.1...0.38).contains(c.greenComponent)
            if abs(x-mid) <= 1 {
                if !red && !blue { return false }
            } else if x < mid ? !blue : !red { return false }
        }
    }
    return true
}

@MainActor private func pointer(_ type: CGEventType, _ point:CGPoint) throws {
    guard let e=CGEvent(mouseEventSource:nil, mouseType:type, mouseCursorPosition:point, mouseButton:.left) else {
        throw ToolRefusal("Could not construct the fixture pointer event")
    }
    e.post(tap:.cghidEventTap)
}

@MainActor private func capture(_ ctx: ToolContext) async throws -> [String:Any] {
    guard try query(ctx,"select id from assets").isEmpty else {throw ToolRefusal("Use an empty isolated screenshot library")}
    guard CGPreflightPostEventAccess(), CGPreflightScreenCaptureAccess() else {throw ToolRefusal("Observer event or screen access unavailable")}
    let fixture=try ToolWindow("capture")
    defer {fixture.close()}
    var selected:CGRect?,obstructions:[[String:Any]]=[],own:CGWindowID=0
    for pose in 0..<4 {
        let state=try await fixture.observe(pose:pose)
        guard let number=state["window"] as? CGWindowID,let regions=state["areas"] as? [String] else {throw ToolRefusal("No capture geometry from the signed fixture")}
        own=number
        await ToolUI.pause(130)
        for value in regions {
            let test=NSRectFromString(value)
            guard test.size==CGSize(width:130,height:76) else {throw ToolRefusal("Unexpected fixture region dimensions")}
            if let blocked=obstruction(to:own,region:test,host:ctx.host.processIdentifier,fixture:fixture.client?.processIdentifier) { obstructions.append(blocked) }
            else {selected=test;break}
        }
        if selected != nil {break}
    }
    guard let area=selected else {
        return ["phase":"capture","status":"BLOCKED","reason":"Every controlled crop intersects an unverified window",
                "captureIssued":false,"obstructions":obstructions]
    }
    let first=CGPoint(x:area.minX,y:area.minY),last=CGPoint(x:area.maxX,y:area.maxY)
    let old=Set(ToolUI.windows(ctx.host.processIdentifier).map(\.id))
    var overlay: Set<CGWindowID> = []
    func freshOverlays() -> Set<CGWindowID> {
        Set(ToolUI.windows(ctx.host.processIdentifier).filter {
            !old.contains($0.id) && $0.level == NSWindow.Level.statusBar.rawValue && $0.bounds.contains(area)
        }.map(\.id))
    }
    defer {
        // Send Escape directly to the installed Host only while this operation's overlay is still alive.
        if !overlay.isDisjoint(with:freshOverlays()) {
            for down in [true,false] { CGEvent(keyboardEventSource:nil,virtualKey:53,keyDown:down)?.postToPid(ctx.host.processIdentifier) }
        }
    }
    guard ToolUI.press(ctx.host,label:"展开截图方式") else {throw ToolRefusal("The production camera control is unavailable")}
    var choosing=false
    for _ in 0..<25 {
        if ToolUI.press(ctx.host,label:"区域截图") {choosing=true;break}
        await ToolUI.pause(100)
    }
    guard choosing else {throw ToolRefusal("The production region capture control is unavailable")}
    for _ in 0..<35 {
        overlay=freshOverlays()
        if !overlay.isEmpty {break}
        await ToolUI.pause(100)
    }
    func clear(_ expected:CGWindowID,ignoring:Set<CGWindowID>=[]) -> Bool {
        obstruction(to:expected,region:area,host:ctx.host.processIdentifier,fixture:fixture.client?.processIdentifier,excluding:ignoring)==nil
    }
    guard overlay.count==1, let selector=overlay.first, clear(selector), clear(own,ignoring:overlay)
    else {throw ToolRefusal("The production selector and the fixture did not own the full requested region")}
    try pointer(.leftMouseDown,first)
    for n in 1...8 {
        let t=CGFloat(n)/8
        try pointer(.leftMouseDragged,CGPoint(x:first.x+(last.x-first.x)*t,y:first.y+(last.y-first.y)*t))
        await ToolUI.pause(15)
    }
    guard clear(selector), clear(own,ignoring:overlay) else {
        for down in [true,false] { CGEvent(keyboardEventSource:nil,virtualKey:53,keyDown:down)?.postToPid(ctx.host.processIdentifier) }
        CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:last,mouseButton:.left)?.postToPid(ctx.host.processIdentifier)
        throw ToolRefusal("A window obscured the controlled region during the drag")
    }
    try pointer(.leftMouseUp,last)
    var rows:[[String:Any]]=[]
    for _ in 0..<65 {
        rows=try query(ctx,"select id,file_name,image_json from assets order by sequence")
        if !rows.isEmpty {break}
        await ToolUI.pause(160)
    }
    guard rows.count==1,let row=rows.first,let id=row["id"] as? String, UUID(uuidString:id) != nil,
          let raw=row["image_json"] as? String, let image=try JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [String:Any],
          image["origin"] as? String == "applicationScreenshot", (image["id"] as? String)?.lowercased()==id.lowercased(),
          let name=image["fileName"] as? String,URL(fileURLWithPath:name).lastPathComponent==name,row["file_name"] as? String==name,
          let expected=image["sha256"] as? String else {throw ToolRefusal("Nearpane did not import one identifiable screenshot")}
    let file=ctx.generation.appendingPathComponent("Riftlet/media").appendingPathComponent(name)
    guard file.resolvingSymlinksInPath().path == file.standardizedFileURL.path else { throw ToolRefusal("The screenshot asset left the isolated media directory") }
    let data=try Data(contentsOf:file), actual=digest(data)
    guard actual==expected,let bitmap=NSBitmapImageRep(data:data) else { throw ToolRefusal("Stored screenshot integrity could not be verified") }
    let scale=bitmap.pixelsWide/130
    let correctSize=(1...4).contains(scale) && abs(bitmap.pixelsWide-130*scale)<=2 && abs(bitmap.pixelsHigh-76*scale)<=2
    let isPattern=correctSize && matchesPattern(bitmap)
    // No screenshot data is exported unless it matches the controlled pattern and exact crop size.
    if isPattern && correctSize {try data.write(to:ctx.output.appendingPathComponent("screenshot.png"),options:.withoutOverwriting)}
    return ["phase":"capture","status":isPattern && correctSize ? "PASS" : "FAIL","hostPID":ctx.host.processIdentifier,
            "generation":ctx.generation.lastPathComponent,"hostExecutableSHA256":try candidateDigest(ctx),
            "assetID":id,"sha256":actual,"width":bitmap.pixelsWide,"height":bitmap.pixelsHigh,"origin":image["origin"] as? String ?? "unknown",
            "ownedPatternMatched":isPattern,"ownedCropSizeMatched":correctSize,"systemRegion":NSStringFromRect(area)]
}

@MainActor private func attach(_ ctx:ToolContext, chrome:pid_t, capture:URL, permissionOnly:Bool) async throws -> [String:Any] {
    let image=try JSONSerialization.jsonObject(with: Data(contentsOf:capture)) as? [String:Any]
    let candidate = try candidateDigest(ctx)
    guard let image,image["status"] as? String == "PASS",image["ownedPatternMatched"] as? Bool == true,
          image["generation"] as? String == ctx.generation.lastPathComponent,image["hostExecutableSHA256"] as? String == candidate,
          let id=image["assetID"] as? String,let hash=image["sha256"] as? String else{throw ToolRefusal("A passing capture from this candidate and isolated generation is required")}
    guard let browser=NSRunningApplication(processIdentifier:chrome), browser.bundleURL?.path=="/Applications/Google Chrome.app",
          NSWorkspace.shared.frontmostApplication?.processIdentifier==chrome,let userData=ProcessInfo.processInfo.environment["NEARPANE_TEST_CHROME_PROFILE"] else {
        throw ToolRefusal("The dedicated browser must own the foreground")
    }
    let args=try ToolUI.run("/bin/ps",["-ww","-p",String(chrome),"-o","command="])
    guard URL(fileURLWithPath:userData).lastPathComponent=="user-data",
          args.components(separatedBy:" ").contains("--user-data-dir="+userData),
          args.contains("--remote-debugging-pipe"), !args.contains("--headless") else {throw ToolRefusal("Chrome process does not own the leased visible profile")}
    let rows=try query(ctx,"select id, sequence, json_extract(image_json,'$.sha256') as hash from assets")
    guard rows.count==1,rows[0]["id"] as? String == id,rows[0]["hash"] as? String == hash,let sequence = rows[0]["sequence"] as? Int,
          try query(ctx,"select id from operations").isEmpty else{throw ToolRefusal("The queue is no longer a fresh single-asset test")}
    if permissionOnly {
        // AX press on a product settings button is equivalent to explicit recheck. The observer never issues an Apple event to Chrome.
        try await ToolUI.openSettings(ctx.host)
        var paneIsReady=false
        for step in 0..<35 {
            let nodes=ToolUI.nodes(ctx.host)
            let labels=nodes.flatMap(ToolUI.labels)
            if labels.contains("允许附加到当前浏览器草稿…") || labels.contains("重新核对草稿附加") || labels.contains("关闭草稿附加") {paneIsReady=true;break}
            if step%6==0,let nav=nodes.first(where:{ToolUI.value($0,kAXIdentifierAttribute) as? String == "settings-nav-tray"}) {
                _ = AXUIElementPerformAction(nav,kAXPressAction as CFString)
            }
            await ToolUI.pause(130)
        }
        guard paneIsReady else{throw ToolRefusal("The installed screenshot settings did not expose draft authorization")}
        browser.activate(options:[])
        for _ in 0..<25 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier==chrome {break}
            await ToolUI.pause(90)
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier==chrome else{throw ToolRefusal("Dedicated Chrome did not regain foreground for authorization")}
        if !ToolUI.nodes(ctx.host).flatMap(ToolUI.labels).contains("关闭草稿附加") {
            guard ToolUI.press(ctx.host,label:"允许附加到当前浏览器草稿…") || ToolUI.press(ctx.host,label:"重新核对草稿附加") else {throw ToolRefusal("The draft authorization control was unavailable")}
        }
        for _ in 0..<40 {
            let saved=try query(ctx,"select hex(value) as consent from checkpoints where key='nearpane-draft-attachments-enabled-v1'")
            if saved.first?["consent"] as? String == "01" {return ["phase":"permission","status":"OBSERVED","hostPID":ctx.host.processIdentifier]}
            await ToolUI.pause(170)
        }
        throw ToolRefusal("Nearpane did not obtain the draft attachment permission for the dedicated Chrome")
    }
    let consent=try query(ctx,"select hex(value) as consent from checkpoints where key='nearpane-draft-attachments-enabled-v1'")
    guard consent.first?["consent"] as? String == "01" else{throw ToolRefusal("The isolated Host has no enabled draft attachment consent")}
    let tiles=ToolUI.nodes(ctx.host).filter{ToolUI.labels($0).contains("附加到草稿，截图 " + String(sequence))}
    guard tiles.count==1,let b=ToolUI.frame(tiles[0]),!b.isEmpty,
          NSWorkspace.shared.frontmostApplication?.processIdentifier==chrome else {throw ToolRefusal("Unique installed thumbnail and frontmost test Chrome required")}
    let point=CGPoint(x:b.midX,y:b.midY)
    guard topOwner(point,excluding:[])?.0 == ctx.host.processIdentifier else{throw ToolRefusal("Another window covers the product thumbnail")}
    // A single mouse-down/up is the only attachment input. Never retry an ambiguous click.
    try pointer(.leftMouseDown,point); await ToolUI.pause(62);try pointer(.leftMouseUp,point)
    return ["phase":"attachmentIntent","status":"ISSUED","hostPID":ctx.host.processIdentifier,"clicks":1,"assetID":id]
}

@main struct CaptureTrial {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in await run() }
        app.run()
    }
    @MainActor static func run() async {
        let args=Array(CommandLine.arguments.dropFirst())
        guard args.count>=2 else{exit(2)}
        let output=URL(fileURLWithPath:args[1])
        do {try FileManager.default.createDirectory(at:output,withIntermediateDirectories:false)}
        catch{print("Use a fresh output directory.");exit(2)}
        let result:[String:Any]
        do {
            let ctx=try ToolContext(output:args[1])
            if args[0]=="capture" && args.count==2 {result=try await capture(ctx)}
            else if ["click","authorize"].contains(args[0]), args.count==4, let pid=Int32(args[2]) {
                result=try await attach(ctx,chrome:pid,capture:URL(fileURLWithPath:args[3]),permissionOnly:args[0]=="authorize")
            } else {throw ToolRefusal("Unknown operation")}
        } catch {result=["phase":args[0],"status":"BLOCKED","reason":error.localizedDescription]}
        do {try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys,.prettyPrinted]).write(to:output.appendingPathComponent("result.json"),options:.withoutOverwriting)}
        catch{exit(2)}
        let status=result["status"] as? String ?? "UNKNOWN"; print(status)
        exit(["PASS","ISSUED","OBSERVED"].contains(status) ? 0 : 3)
    }
}
