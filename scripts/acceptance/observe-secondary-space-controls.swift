// Inspect only the Dock's visible Mission Control controls. Never opens the overview or posts an action.
import AppKit
import ApplicationServices

struct Refusal: Error {
  let reason: String
  init(_ reason: String) { self.reason = reason }
}

func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
    return nil
  }
  return value
}

func children(_ parent: AXUIElement, named id: String) throws -> [AXUIElement] {
  guard let children = attr(parent, kAXChildrenAttribute) as? [AXUIElement], children.count <= 256
  else {
    throw Refusal("Dock control children unavailable or unbounded")
  }
  // No descriptions, titles, documents, pixels, or descent into application windows.
  return children.filter { attr($0, kAXIdentifierAttribute) as? String == id }
}

func only(_ elements: [AXUIElement], _ label: String) throws -> AXUIElement {
  guard elements.count == 1 else { throw Refusal("missing or ambiguous " + label) }
  return elements[0]
}

func observe(_ displayUUID: UUID) throws -> [String: Any] {
  guard AXIsProcessTrusted(), let state = CGSessionCopyCurrentDictionary() as? [String: Any],
    state["kCGSSessionOnConsoleKey"] as? Bool == true,
    state["CGSSessionScreenIsLocked"] as? Bool != true
  else { throw Refusal("unlocked console and existing AX permission required") }
  let displays = NSScreen.screens.compactMap {
    ($0.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.uint32Value
  }
  guard displays.count == 2, Set(displays).count == 2, displays.contains(CGMainDisplayID()),
    let side = displays.first(where: { $0 != CGMainDisplayID() }),
    CGDisplayIsInMirrorSet(side) == 0,
    !CGDisplayBounds(side).intersects(CGDisplayBounds(CGMainDisplayID())),
    let raw = CGDisplayCreateUUIDFromDisplayID(side)?.takeRetainedValue(),
    UUID(uuidString: CFUUIDCreateString(nil, raw) as String) == displayUUID
  else {
    throw Refusal("secondary identity or topology changed")
  }
  let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
  guard apps.count == 1, let dock = apps.first, !dock.isTerminated,
    dock.executableURL?.resolvingSymlinksInPath().path
      == "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"
  else {
    throw Refusal("unique running system Dock unavailable")
  }
  let root = AXUIElementCreateApplication(dock.processIdentifier)
  AXUIElementSetMessagingTimeout(root, 1)
  let groups = try children(root, named: "mc")
  var result: [String: Any] = [
    "display": displayUUID.uuidString, "systemInputs": 0,
    "sampledAt": ISO8601DateFormatter().string(from: Date()),
  ]
  guard !groups.isEmpty else {
    result["state"] = "overviewNotExposed"
    return result
  }
  let group = try only(groups, "overview")
  let containers = try children(group, named: "mc.display")
  let secondary = try only(
    containers.filter { (attr($0, "AXDisplayID") as? NSNumber)?.uint32Value == side },
    "secondary display group")
  let spaces = try only(children(secondary, named: "mc.spaces"), "secondary spaces bar")
  let button = try only(children(spaces, named: "mc.spaces.add"), "secondary add button")
  var actions: CFArray?
  guard attr(button, kAXRoleAttribute) as? String == kAXButtonRole,
    attr(button, kAXEnabledAttribute) as? Bool == true,
    AXUIElementCopyActionNames(button, &actions) == .success,
    (actions as? [String])?.contains(kAXPressAction as String) == true
  else {
    throw Refusal("enabled secondary add control not confirmed")
  }
  result["state"] = "secondaryAddControlObserved"
  result["primaryOverviewContainerPresent"] = containers.contains {
    (attr($0, "AXDisplayID") as? NSNumber)?.uint32Value == CGMainDisplayID()
  }
  return result
}

#if !SECONDARY_OVERVIEW_DRIVER
  @main struct ObserverMain {
    static func main() {
      do {
        guard CommandLine.arguments.count == 2,
          let display = UUID(uuidString: CommandLine.arguments[1])
        else {
          throw Refusal("expected secondary display UUID")
        }
        let data = try JSONSerialization.data(
          withJSONObject: observe(display), options: [.sortedKeys])
        FileHandle.standardOutput.write(data + Data("\n".utf8))
      } catch {
        FileHandle.standardError.write(
          Data(((error as? Refusal)?.reason ?? "observation unavailable").utf8))
        exit(2)
      }
    }
  }
#endif
