import AppKit
import CoreGraphics

/// A passive tap on one verified Host PID. The OS never sends keyboard events to this
/// tap. The callback discards every mouse event without our per-gesture random tag.
final class PairPointerReceiver {
    let host: pid_t, source = getpid(), tag: Int64, panel: UInt32
    private var port: CFMachPort?, loopSource: CFRunLoopSource?
    private var received = [Object]()
    private var disabled = false, truncated = false

    init(host: pid_t, panel: UInt32, tag: Int64) {
        self.host = host; self.panel = panel; self.tag = tag
        let mask = [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        port = CGEvent.tapCreateForPid(pid: host, place: .tailAppendEventTap, options: .listenOnly,
                                      eventsOfInterest: mask, callback: { _, type, event, context in
            if let context {
                let witness = Unmanaged<PairPointerReceiver>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    witness.disabled = true
                } else if event.getIntegerValueField(.eventSourceUserData) == witness.tag {
                    witness.observe(type, event)
                }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let port, let source = CFMachPortCreateRunLoopSource(nil, port, 0) else { return }
        loopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    private func observe(_ type: CGEventType, _ event: CGEvent) {
        guard [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(type) else { return }
        guard received.count < 48 else { truncated = true; return }
        func window(_ key: CGEventField) -> String {
            let id = event.getIntegerValueField(key)
            return id == Int64(panel) ? "boundPanel" : id == 0 ? "unreported" : "different"
        }
        func process(_ key: CGEventField, _ expected: pid_t) -> String {
            let pid = event.getIntegerValueField(key)
            return pid == Int64(expected) ? "bound" : pid == 0 ? "unreported" : "different"
        }
        received.append(["type":type.rawValue,"observedAt":ProcessInfo.processInfo.systemUptime,
                         "timestampNS":event.timestamp, "point":[event.location.x,event.location.y],
                         "quartzDelta":[event.getIntegerValueField(.mouseEventDeltaX),event.getIntegerValueField(.mouseEventDeltaY)],
                         "source":process(.eventSourceUnixProcessID,source), "destination":process(.eventTargetUnixProcessID,host),
                         "underPointer":window(.mouseEventWindowUnderMousePointer),
                         "acceptingPointer":window(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)] as Object)
    }

    // Pump this thread's ordinary CF run loop. NSWorkspace notifications, as well as
    // the PID tap, can now advance while the bounded native focus observer is resident.
    static func pump(_ seconds: Double) {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if CFRunLoopRunInMode(.defaultMode, max(0.0001,remaining), true) == .finished {
                Thread.sleep(forTimeInterval:max(0,deadline-ProcessInfo.processInfo.systemUptime))
            }
        }
    }

    func receipt() -> Object {
        let status = port == nil || loopSource == nil ? "UNAVAILABLE" : disabled ? "INTERRUPTED" :
            truncated ? "TRUNCATED" : received.isEmpty ? "NO_TAGGED_EVENTS" : "OBSERVED"
        return ["scope":"WindowServer routed to enrolled Host PID", "hostPID":host,"senderPID":source,
                "tag":tag,"status":status,"events":received,"AppKitCallback":"NOT_OBSERVED"] as Object
    }

    func close() {
        if let port { CGEvent.tapEnable(tap:port,enable:false) }
        if let loopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), loopSource, .defaultMode) }
        if let port { CFMachPortInvalidate(port) }
    }
}
