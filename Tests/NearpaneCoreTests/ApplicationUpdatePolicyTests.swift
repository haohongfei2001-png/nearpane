import Foundation
import Testing
@testable import NearpaneCore

@Suite("Application update admission")
struct ApplicationUpdatePolicyTests {
    private var info: [String: Any] {
        ["CFBundleIdentifier": "com.holdsnow.nearpane.alpha",
         "SUFeedURL": ApplicationUpdatePolicy.feedURL,
         "SUPublicEDKey": Data(repeating: 3, count: 32).base64EncodedString(),
         "SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true,
         "SUSignedFeedFailureExpirationInterval": 0, "SUAllowsAutomaticUpdates": false,
         "SUAutomaticallyUpdate": false, "SUScheduledCheckInterval": 86_400.0]
    }

    @Test func exactIndependentChannelAndConsentPolicy() {
        #expect(ApplicationUpdatePolicy.configurationProblem(info) == nil)
        let changes: [(String, Any)] = [
            ("CFBundleIdentifier", "com.riftlet.app"),
            ("SUFeedURL", "https://riftlet.com/updates/stable.xml"),
            ("SUPublicEDKey", Data(repeating: 0, count: 32).base64EncodedString()),
            ("SURequireSignedFeed", false), ("SUVerifyUpdateBeforeExtraction", false),
            ("SUSignedFeedFailureExpirationInterval", 86400),
            ("SUAllowsAutomaticUpdates", true), ("SUAutomaticallyUpdate", true),
            ("SUScheduledCheckInterval", 3600.0)
        ]
        for (key, value) in changes {
            var invalid = info; invalid[key] = value
            #expect(ApplicationUpdatePolicy.configurationProblem(invalid) != nil)
        }
        var missing = info; missing.removeValue(forKey: "SUPublicEDKey")
        #expect(ApplicationUpdatePolicy.configurationProblem(missing) != nil)
    }

    @Test func signedVersionAndBuildMustBothAdvance() {
        #expect(ApplicationUpdatePolicy.accepts(currentVersion: "5.9", currentBuild: "59",
            candidateVersion: "5.10", candidateBuild: "60", feedSignatureValid: true))
        #expect(ApplicationUpdatePolicy.accepts(currentVersion: "5.9", currentBuild: "59",
            candidateVersion: "5.9.1", candidateBuild: "60", feedSignatureValid: true))
        for (version, build, signed) in [("5.10", "60", false), ("5.9", "60", true),
            ("5.8.9", "100", true), ("5.10", "59", true), ("05.10", "60", true),
            ("5.10", "060", true), ("5.10-beta", "60", true), ("5.10.0.1", "60", true)] {
            #expect(!ApplicationUpdatePolicy.accepts(currentVersion: "5.9", currentBuild: "59",
                candidateVersion: version, candidateBuild: build, feedSignatureValid: signed))
        }
    }

    @Test func installerOutlivesTheUIAndDownloadCancellation() {
        var admission = UpdateInstallationAdmission()
        #expect(admission.permitsProfileSwitch(sessionInProgress: false, installationDeferred: false))
        #expect(!admission.permitsProfileSwitch(sessionInProgress: true, installationDeferred: false))
        admission.acceptDownload()
        #expect(!admission.permitsProfileSwitch(sessionInProgress: false, installationDeferred: false))
        admission.cancelDownload()
        #expect(admission.permitsProfileSwitch(sessionInProgress: false, installationDeferred: false))
        admission.acceptDownload()
        admission.acceptInstallation()
        admission.cancelDownload()
        #expect(admission.phase == .installerAccepted)
        #expect(!admission.permitsProfileSwitch(sessionInProgress: false, installationDeferred: false))
        #expect(!UpdateInstallationAdmission().permitsProfileSwitch(sessionInProgress: false, installationDeferred: true))
    }
}
