import Foundation
import Testing
import WindowLab

struct ConsoleConsentTests {
    @Test func fullscreenGrantCannotAuthorizeRouteAndRouteCannotEnterFullscreen() throws {
        let run = UUID(), display = UUID().uuidString, now = Date()
        var payload: [String:Any] = ["run":run.uuidString, "secondaryDisplay":display, "boot":"boot",
            "securityID":12, "source":"87", "target":"", "permitsCalibrationAndThreeRoundTrips":false,
            "permitsSingleWindowFullscreen":true, "starts":now.addingTimeInterval(-1).timeIntervalSinceReferenceDate,
            "ends":now.addingTimeInterval(100).timeIntervalSinceReferenceDate]
        func allowed(fullscreen: Bool) throws -> Bool {
            let grant = try JSONDecoder().decode(ConsoleSpaceConsent.self, from: JSONSerialization.data(withJSONObject: payload))
            return grant.allows(run: run, boot: "boot", securityID: 12, display: display, at: now, fullscreenOnly: fullscreen)
        }
        #expect(try allowed(fullscreen: true))
        #expect(try !allowed(fullscreen: false))
        payload["permitsCalibrationAndThreeRoundTrips"] = true; payload["target"] = "88"
        #expect(try !allowed(fullscreen: true))
        #expect(try !allowed(fullscreen: false))
        payload.removeValue(forKey: "permitsSingleWindowFullscreen")
        #expect(try !allowed(fullscreen: true))
        #expect(try allowed(fullscreen: false))
    }

    @Test(arguments: [nil, false, true] as [Bool?])
    func focusOnlyBorrowsFromAnIdentifiedDisplayWithExplicitConsent(granted: Bool?) throws {
        var data: [String:Any] = ["run":UUID().uuidString, "secondaryDisplay":UUID().uuidString,
                                  "boot":"boot", "securityID":4, "source":"8", "target":"9",
                                  "starts":1, "ends":800, "permitsCalibrationAndThreeRoundTrips":true]
        data["permitsTemporarySecondaryFocus"] = granted
        let consent = try JSONDecoder().decode(ConsoleSpaceConsent.self, from: JSONSerialization.data(withJSONObject: data))
        #expect(consent.acceptsFocusRegion("secondary"))
        #expect(consent.acceptsFocusRegion("protected-main") == (granted == true))
        #expect(!consent.acceptsFocusRegion("spanning"))
        #expect(!consent.acceptsFocusRegion("unknown"))
    }

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
