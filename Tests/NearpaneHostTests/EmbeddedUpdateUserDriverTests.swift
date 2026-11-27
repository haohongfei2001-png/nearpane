#if canImport(Sparkle)
import AppKit
import Sparkle
import Testing
@testable import NearpaneHost

@MainActor @Suite struct EmbeddedUpdateUserDriverTests {
    @Test func checkingCancellationAndInstallConfirmationStayInExistingWindow() {
        let existing = Set(NSApplication.shared.windows.map(\.windowNumber))
        let driver = EmbeddedUpdateUserDriver()
        var navigationRequests = 0
        var cancellations = 0
        var installChoices: [SPUUserUpdateChoice] = []
        driver.requestManagement = { navigationRequests += 1 }
        driver.showUserInitiatedUpdateCheck { cancellations += 1 }
        #expect(driver.phase == .checking)
        #expect(navigationRequests == 1 && cancellations == 0)
        driver.performSecondary(); driver.performSecondary()
        #expect(cancellations == 1)
        driver.showReady(toInstallAndRelaunch: { installChoices.append($0) })
        #expect(driver.phase == .ready && installChoices.isEmpty)
        driver.performPrimary(); driver.performPrimary()
        #expect(installChoices == [.install])
        #expect(Set(NSApplication.shared.windows.map(\.windowNumber)) == existing)
    }

    @Test func extractionRevokesDownloadCancellationAndProgressIsBounded() {
        let driver = EmbeddedUpdateUserDriver()
        var cancellations = 0
        driver.showDownloadInitiated { cancellations += 1 }
        driver.showDownloadDidReceiveExpectedContentLength(0)
        driver.showDownloadDidReceiveData(ofLength: UInt64.max)
        #expect(driver.progress == nil)
        driver.showDownloadDidReceiveData(ofLength: UInt64.max)
        driver.showDownloadDidReceiveExpectedContentLength(10)
        #expect(driver.progress == 1)
        driver.showDownloadDidStartExtractingUpdate()
        driver.performSecondary()
        #expect(cancellations == 0)
        driver.showExtractionReceivedProgress(.infinity)
        #expect(driver.progress == nil)
        driver.showExtractionReceivedProgress(-0.5)
        #expect(driver.progress == 0)
        driver.showExtractionReceivedProgress(1.5)
        #expect(driver.progress == 1)
    }

    @Test func dismissalAndStoppingInvalidatePendingActions() {
        let driver = EmbeddedUpdateUserDriver()
        var calls = 0
        driver.showReady(toInstallAndRelaunch: { _ in calls += 1 })
        driver.dismissUpdateInstallation()
        driver.performPrimary()
        #expect(calls == 0 && driver.phase == .idle)
        driver.showDownloadInitiated { calls += 1 }
        driver.stop()
        driver.performSecondary()
        #expect(calls == 0)
    }

    @Test func errorAcknowledgementRunsOnceWithoutAnAlert() {
        let existing = Set(NSApplication.shared.windows.map(\.windowNumber))
        let driver = EmbeddedUpdateUserDriver()
        var acknowledgements = 0
        var status = ""
        driver.reportStatus = { status = $0 }
        driver.showUpdaterError(NSError(domain: "native-verification", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Download failed"]), acknowledgement: { acknowledgements += 1 })
        #expect(driver.phase == .result && status.contains("Download failed"))
        driver.performPrimary(); driver.performPrimary()
        #expect(acknowledgements == 1)
        #expect(Set(NSApplication.shared.windows.map(\.windowNumber)) == existing)
    }

    @Test func releaseNotesRemainInertTextAndCannotRunEmbeddedContent() {
        let html = "<h2>New version</h2><script>alert('not a UI')</script><p>Faster &amp; clearer</p><img src='https://example.invalid/tracker'>"
        let plain = UpdateReleaseNotesText.plain(html)
        #expect(plain == "New version\nFaster & clearer")
        #expect(UpdateReleaseNotesText.plain("") == nil)
        #expect(UpdateReleaseNotesText.plain(String(repeating: "a", count: 100_000))?.count == 65_536)
    }
}
#endif
