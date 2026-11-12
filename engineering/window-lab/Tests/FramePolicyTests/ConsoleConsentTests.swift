import Foundation
import Testing
import WindowLab

struct ConsoleConsentTests {
    @Test(arguments: ["valid", "future", "expired", "too-long", "replay", "different-boot", "changed-login",
                      "different-display", "same-space", "invalid-id", "not-authorized"])
    func scopeAndIntervalRemainBound(reason: String) throws {
        let run = UUID(), display = UUID().uuidString, now = Date()
        let values: [String:Any] = ["run": run.uuidString, "boot":"boot", "securityID":12, "secondaryDisplay":display,
            "source":"87", "target":reason == "same-space" ? "87" : reason == "invalid-id" ? "0" : "42",
            "starts":now.addingTimeInterval(reason == "future" ? 2 : -2).timeIntervalSinceReferenceDate,
            "ends":now.addingTimeInterval(reason == "expired" ? 0 : reason == "too-long" ? 901 : 300).timeIntervalSinceReferenceDate,
            "permitsCalibrationAndThreeRoundTrips": reason != "not-authorized"]
        let consent = try JSONDecoder().decode(ConsoleSpaceConsent.self, from: JSONSerialization.data(withJSONObject: values))
        #expect(consent.allows(run: reason == "replay" ? UUID() : run, boot: reason == "different-boot" ? "new" : "boot",
                               securityID: reason == "changed-login" ? 14 : 12, display: reason == "different-display" ? UUID().uuidString : display,
                               at: now) == (reason == "valid"))
    }
}
