import Foundation
import Testing
import WindowLab

struct FullscreenToolCheckpointTests {
    @Test(arguments: ["valid", "old-token", "other-host", "restarted-witness", "expired", "other-display",
                      "changed-number", "wrong-run", "no-receipt", "unknown-result"])
    func replyBindsWindowRunAndLiveTime(_ scenario: String) throws {
        let id = UUID(), display = UUID().uuidString, sha = String(repeating: "e", count: 64)
        let challenge = FullscreenToolChallenge(run: id, display: display, source: "7", fullscreenCurrent: "8", boot: "boot",
            build: "26A428", pid: 42, launch: 17, number: 58, revision: 21, expiresUptime: 120, witnessSHA256: sha, readerSHA256: sha)
        var data: [String:Any] = ["run":id.uuidString, "token":challenge.token.uuidString, "pid":42, "launch":17, "number":58,
                                  "display":display, "hostPID":101, "receiptSHA256":sha, "result":"observed"]
        switch scenario {
        case "old-token": data["token"] = UUID().uuidString
        case "other-host": data["hostPID"] = 42
        case "restarted-witness": data["launch"] = 18
        case "other-display": data["display"] = UUID().uuidString
        case "changed-number": data["number"] = 59
        case "wrong-run": data["run"] = UUID().uuidString
        case "no-receipt": data["receiptSHA256"] = ""
        case "unknown-result": data["result"] = "success"
        default: break
        }
        let raw = try JSONSerialization.data(withJSONObject: data)
        let reply = try? JSONDecoder().decode(FullscreenToolReply.self, from: raw)
        #expect((reply?.matches(challenge, uptime: scenario == "expired" ? 120 : 119) == true) == (scenario == "valid"))
    }
}
