import AppKit

// Replay the P4.2 coordinate question on its recorded topology. These windows are never ordered.
_ = NSApplication.shared.setActivationPolicy(.prohibited)
let displays = NSScreen.screens
guard displays.count == 2, let number = displays[1].deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
      number.uint32Value != CGMainDisplayID(), CGDisplayIsInMirrorSet(number.uint32Value) == 0,
      CGDisplayBounds(number.uint32Value) == CGRect(x: -800, y: 0, width: 800, height: 1280),
      CGDisplayRotation(number.uint32Value) == 90 else { exit(2) }
let secondary = displays[1]
let styles: [(String, NSWindow.StyleMask)] = [
    ("titled", [.titled, .resizable, .miniaturizable, .closable]), ("borderless", .borderless)
]
for (kind, style) in styles {
    let window = NSWindow(contentRect: .zero, styleMask: style, backing: .buffered, defer: true, screen: secondary)
    window.minSize = .init(width: 144, height: 96)
    for width: CGFloat in [240, 320] {
        let proposed = CGRect(x: -800 - width - 2, y: displays[0].frame.maxY - 1034 - 160, width: width, height: 160)
        print(kind, width, "proposed", proposed, "constrain", window.constrainFrameRect(proposed, to: secondary),
              "visible", window.isVisible)
    }
}
