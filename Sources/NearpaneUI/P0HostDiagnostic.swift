#if NEARPANE_P0_DIAGNOSTIC
import AppKit
import NearpaneCore

/// Safe even while Stage Manager owns sidebar presentation. The signed Host sends a
/// real .probe to the packaged action worker, and records the nonce under its own profile.
@MainActor package enum P0HostProbe {
    package static func run(nonce: UUID, profile: URL, stageOwnsDispatch: Bool) async -> Bool {
        guard let lease = P0DiagnosticLease.installed(),
              profile.path == lease.home.appendingPathComponent("Library/Application Support/Nearpane Alpha Profiles").path,
              let generation = try? JSONSerialization.jsonObject(with: Data(contentsOf:profile.appendingPathComponent("profile-index.json"))) as? [String:Any],
              let active = generation["active"] as? String, UUID(uuidString:active) != nil,
              let host = try? OrdinaryProcessImage.read(getpid()) else { return false }
        let command = NativeSpaceCommand(id:nonce,action:.probe,display:"",source:"",target:"")
        let reply = await NativeSpaceActionClient.shared.run(command)
        let result: [String:Any] = ["nonce":nonce.uuidString,"action":"probe","operation":reply.id.uuidString,"state":reply.state.rawValue,
            "canSwitch":reply.canSwitch,"canMove":reply.canMove,"submittedSteps":reply.submittedSteps,"issued":reply.issuedAtUptime != nil,
            "stageManagerOwnsDispatch":stageOwnsDispatch,"pid":getpid(),"birth":host.launch,"generation":active,"revision":lease.revision,
            "at":ProcessInfo.processInfo.systemUptime]
        guard let raw = try? JSONSerialization.data(withJSONObject:result) else { return false }
        do {
            try raw.write(to:lease.home.appendingPathComponent("p0-probe-"+nonce.uuidString+".json"),options:.withoutOverwriting)
            return true
        } catch { return false }
    }
}

#endif
