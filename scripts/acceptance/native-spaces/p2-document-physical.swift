import AppKit

// Event counts only. Pointer travel has no authority to change the foreground.
func p2Physical()->[UInt32] {
    let types:[CGEventType] = [.leftMouseDown,.rightMouseDown,.otherMouseDown,.keyDown,.scrollWheel,.keyUp,
                               .flagsChanged,.leftMouseUp,.rightMouseUp,.otherMouseUp,.leftMouseDragged,.rightMouseDragged,.otherMouseDragged]
    return types.map { CGEventSource.counterForEventType(.hidSystemState,eventType:$0) }
}
