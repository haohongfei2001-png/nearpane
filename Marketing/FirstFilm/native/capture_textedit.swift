import AppKit
import ApplicationServices
import Foundation
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
func escaped(_ text: String) -> String {
    text.utf16.map { value -> String in
        if value == 92 { return "\\\\" }
        if value == 123 { return "\\{" }
        if value == 125 { return "\\}" }
        if value > 127 { return "\\u\(Int16(bitPattern:value))?" }
        return String(UnicodeScalar(value)!)
    }.joined()
}
func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element,key as CFString,&value) == .success ? value : nil
}
func children(_ element: AXUIElement) -> [AXUIElement] { attribute(element,kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func title(_ element: AXUIElement) -> String { attribute(element,kAXTitleAttribute) as? String ?? "" }
func descendants(_ element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 6 else { return [] }
    let next=children(element);return next+next.flatMap { descendants($0,depth:depth+1) }
}
func escapeMenu() {
    CGEvent(keyboardEventSource:nil,virtualKey:53,keyDown:true)?.post(tap:.cghidEventTap)
    CGEvent(keyboardEventSource:nil,virtualKey:53,keyDown:false)?.post(tap:.cghidEventTap)
}
var menuActions:[[String:Any]]=[]
func simplifyChrome(pid:pid_t) {
    guard AXIsProcessTrusted() else { return }
    let app=AXUIElementCreateApplication(pid)
    guard let raw=attribute(app,kAXMenuBarAttribute) else { return }
    let bar=raw as! AXUIElement
    for item in children(bar) where ["View","Format"].contains(title(item)) {
        let menuName=title(item)
        _=AXUIElementPerformAction(item,kAXPressAction as CFString)
        Thread.sleep(forTimeInterval:0.12)
        if let textMenu=descendants(item).first(where:{title($0)=="Text"}) {
            _=AXUIElementPerformAction(textMenu,kAXPressAction as CFString)
            Thread.sleep(forTimeInterval:0.12)
        }
        for target in descendants(item) where ["Hide Ruler","Hide Toolbar"].contains(title(target)) {
            let label=title(target)
            let result=AXUIElementPerformAction(target,kAXPressAction as CFString)
            menuActions.append(["menu":menuName,"observedTitle":label,"result":result.rawValue])
            Thread.sleep(forTimeInterval:0.12)
        }
        escapeMenu()
    }
}
for language in ["zh","en"] {
    let fileName=language == "zh" ? "留白" : "A quiet moment"
    let heading=language == "zh" ? "今天，慢一点。" : "Today, a little slower."
    let paragraphs=language == "zh" ? ["把目光留在正在做的事上。","喜欢的旋律，依然在身边。","一些灵感，留给此刻。"] : ["Stay with what you are doing.","Let the music stay close.","Leave a little room for a thought."]
    let font=language == "zh" ? "PingFang SC" : "Helvetica Neue"
    let rtf="{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 "+font+";}}{\\colortbl;\\red40\\green45\\blue53;}\\f0\\cf1\\pard\\li1200\\ri1200\\sb1000\\sa500\\fs64 "+escaped(heading)+"\\par\\pard\\li1200\\ri1200\\sb200\\sa320\\sl480\\fs36 "+paragraphs.map(escaped).joined(separator:"\\par ")+"}"
    let file=out.appendingPathComponent(fileName+".rtf")
    try rtf.write(to:file,atomically:true,encoding:.utf8)
    let screen=NSScreen.main?.frame ?? NSRect(x:0,y:0,width:1440,height:900)
    let right=min(1200,Int(screen.width)-40), bottom=min(800,Int(screen.height)-40)
    let script="tell application \"TextEdit\"\nactivate\nopen POSIX file \"\(file.path)\"\ndelay 1\nset bounds of front window to {40, 80, \(right), \(bottom)}\nend tell"
    let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/bin/osascript");p.arguments=["-e",script]
    let pipe=Pipe();p.standardOutput=pipe;p.standardError=pipe;try p.run();p.waitUntilExit()
    let response=String(data:pipe.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8) ?? ""
    Thread.sleep(forTimeInterval:0.3)
    if let app=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.TextEdit").first { simplifyChrome(pid:app.processIdentifier) }
    Thread.sleep(forTimeInterval:0.35)
    let windows=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
    if let window=windows.first(where:{($0[kCGWindowOwnerName as String] as? String)=="TextEdit" && ($0[kCGWindowLayer as String] as? Int)==0}),let id=window[kCGWindowNumber as String] as? Int {
        let shot=Process();shot.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture");shot.arguments=["-x","-l",String(id),out.appendingPathComponent("textedit-"+language+"-native.png").path];try shot.run();shot.waitUntilExit()
        let report:[String:Any] = ["kind":"actual TextEdit WindowServer screenshot","owner":"TextEdit","windowID":id,"captureExitCode":shot.terminationStatus,"content":"Original HOLDSNOW film text","language":language,"hostScale":"Actual display scale, not enlarged","requestedBounds":[40,80,right,bottom],"observedWindowBounds":window[kCGWindowBounds as String] as Any? ?? NSNull(),"appleScriptExitCode":p.terminationStatus,"appleScriptResponse":response,"observedMenuActions":menuActions]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("textedit-"+language+"-source.json"))
    }
}
