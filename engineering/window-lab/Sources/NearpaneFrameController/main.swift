import AppKit
import ApplicationServices
import NearpaneCore
import WindowLab

private struct Preflight: Encodable {
    let visibilityProtocolVersion = 1
    let virtualSwitchAvailable: Bool
    let trusted: Bool, screens: Screens, parent: ProcessBirth, uptime: Double, controllerID: String?
}
do {
    // No call capable of prompting, activating, raising, clicking or switching a Space.
    NSApplication.shared.setActivationPolicy(.prohibited)
    let args = Array(CommandLine.arguments.dropFirst())
    if args == ["preflight"] {
        try emit(Preflight(virtualSwitchAvailable: VirtualWorkspacesProvider().deviceCapabilities(build: ProcessInfo.processInfo.operatingSystemVersionString, displayID: try Screens.read().0.secondary).permits(.switchRow, isolated: false), trusted: AXIsProcessTrusted(), screens: try Screens.read().0, parent: try .read(getppid()),
                           uptime: ProcessInfo.processInfo.systemUptime, controllerID: Bundle.main.bundleIdentifier))
    } else if args.count == 2 {
        let verb = args[0], directory = URL(fileURLWithPath: args[1], isDirectory: true)
        if ["mini-read","mini-recover"].contains(verb) {
            try emit(try MinimizeStudy(directory).perform(verb))
        } else if verb == "inspect" || verb == "observe" {
            let a = try FixtureAdapter(directory)
            try emit(try a.ticket.members.map { try verb == "inspect" ? a.cg($0) : a.observe($0) })
        } else if verb == "presentation" {
            try emit(try presentation(FixtureAdapter(directory)))
        } else if verb == "refuse-minimum" {
            let a = try FixtureAdapter(directory), m = a.ticket.members[0], old = try a.observe(m).cg
            var small = old; small.width = m.minimum.width - 1
            _ = try a.set(m, from: old, to: small, parking: false)
            throw Refusal("minimum gate unexpectedly admitted input")
        } else if verb == "panel-observe" {
            try emit(try panelObservation(FixtureAdapter(directory)))
        } else if verb == "confirm-exit" {
            try emit(try confirmExit(directory))
        } else if verb == "recover" || verb == "recover-denied" {
            try emit(try Experiment(directory, acceptsAX: verb != "recover-denied").recover())
        } else if ["canary", "canary-and-hold", "docked", "floating", "reserve", "custom-pair", "original", "park", "switch", "switch-and-hold"].contains(verb) {
            try emit(try Experiment(directory).begin(verb))
        } else { throw Refusal("unknown controller command") }
    } else {
        throw Refusal("expected a private fixture session")
    }
} catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
