// A regular AppKit client, launched by Launch Services. It only manages its own window and local fixture files.
import AppKit

let app = NSApplication.shared
let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 2, ["selection","capture"].contains(args[0]),
      Bundle.main.bundleIdentifier == "org.nearpane.acceptance.tool-window" else { exit(2) }
let dir = URL(fileURLWithPath:args[1]).resolvingSymlinksInPath()
guard UUID(uuidString:dir.lastPathComponent) != nil else { exit(2) }
var directoryInfo = stat()
guard lstat(dir.path,&directoryInfo)==0, directoryInfo.st_uid==getuid(), directoryInfo.st_mode & 0o077==0 else { exit(2) }
let capture = args[0] == "capture"
app.setActivationPolicy(.regular)
NSWindow.allowsAutomaticWindowTabbing = false
final class Pattern: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect:NSRect) {
        NSColor(srgbRed:0.84,green:0.22,blue:0.12,alpha:1).setFill()
        NSBezierPath(rect:bounds).fill()
        NSColor(srgbRed:0.10,green:0.34,blue:0.88,alpha:1).setFill()
        NSBezierPath(rect:NSRect(x:0,y:0,width:bounds.width/2,height:bounds.height)).fill()
    }
}
let size = capture ? CGSize(width:480,height:260) : CGSize(width:460,height:150)
let window = NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:[.titled],backing:.buffered,defer:false)
window.isReleasedWhenClosed=false; window.title="Nearpane controlled tool fixture"
let field = NSTextView(frame:NSRect(x:25,y:38,width:411,height:70))
if capture {
    window.level = .statusBar; window.contentView=Pattern(frame:NSRect(origin:.zero,size:size))
} else {
    field.isRichText=false;field.isEditable=true;field.isSelectable=true
    field.font = .systemFont(ofSize:23);field.string="The blue bicycle"
    window.contentView?.addSubview(field)
}
var pose = -1, selected = false, last = Data()
var serviceAttempted=false,serviceDispatched=false,board:NSPasteboard?
let started = ProcessInfo.processInfo.systemUptime
func quartz(_ rect:NSRect) -> String {
    NSStringFromRect(NSRect(x:rect.minX,y:(NSScreen.screens.first?.frame.maxY ?? 0)-rect.maxY,width:rect.width,height:rect.height))
}
DispatchQueue.main.async {
    window.center();window.makeKeyAndOrderFront(nil);app.activate(ignoringOtherApps:true)
}
let timer = Timer(timeInterval:0.06,repeats:true) { _ in
    if FileManager.default.fileExists(atPath:dir.appendingPathComponent("close").path) || ProcessInfo.processInfo.systemUptime-started>90 {
        board?.releaseGlobally()
        try? Data().write(to:dir.appendingPathComponent("closed"))
        window.close(); app.terminate(nil); return
    }
    guard let screen=window.screen ?? NSScreen.main,let view=window.contentView else { return }
    let request=(try? String(contentsOf:dir.appendingPathComponent("pose"),encoding:.utf8)).flatMap(Int.init) ?? 0
    let positions=[(0.50,0.5),(0.26,0.7),(0.68,0.65),(0.45,0.22)]
    if capture && positions.indices.contains(request) && pose != request {
        let (x,y)=positions[request], frame=screen.visibleFrame
        window.setFrameOrigin(CGPoint(x:(frame.minX+(frame.width-window.frame.width)*x).rounded(),y:(frame.minY+(frame.height-window.frame.height)*y).rounded()))
        window.orderFrontRegardless();pose=request
    }
    let front=NSWorkspace.shared.frontmostApplication?.processIdentifier==getpid()
    if front && !window.isKeyWindow && !selected { window.makeKeyAndOrderFront(nil) }
    if !capture && front && window.isKeyWindow && !selected {
        selected=window.makeFirstResponder(field)
        field.setSelectedRange(NSRange(location:0,length:(field.string as NSString).length))
    }
    let focused=window.isKeyWindow && front && (capture || (selected && window.firstResponder===field && field.selectedRange().length==(field.string as NSString).length))
    if !capture, focused, !serviceAttempted, FileManager.default.fileExists(atPath:dir.appendingPathComponent("perform-service").path) {
        serviceAttempted=true
        let privateBoard=NSPasteboard.withUniqueName()
        board=privateBoard
        if privateBoard.setString(field.string,forType:.string) {serviceDispatched=NSPerformService("在 Nearpane 翻译选词",privateBoard)}
    }
    let areas=[0.5,0.3,0.7].map { fraction in
        let crop=NSRect(x:view.bounds.midX-65,y:(view.bounds.height*fraction).rounded()-38,width:130,height:76)
        return quartz(window.convertToScreen(view.convert(crop,to:nil)))
    }
    var state:[String:Any]=["session":dir.lastPathComponent,"kind":args[0],"pid":getpid(),"window":window.windowNumber,
                           "key":window.isKeyWindow,"front":front,"focused":focused,"pose":capture ? pose:0,"areas":areas,
                           "serviceAttempted":serviceAttempted,"serviceDispatched":serviceDispatched]
    if !capture && focused { state["selection"]=quartz(field.firstRect(forCharacterRange:field.selectedRange(),actualRange:nil)) }
    if let data=try? JSONSerialization.data(withJSONObject:state,options:.sortedKeys),data != last {
        try? data.write(to:dir.appendingPathComponent("state.json"),options:.atomic);last=data
    }
}
RunLoop.main.add(timer,forMode:.common)
app.run()
