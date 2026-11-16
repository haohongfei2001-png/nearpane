import Foundation
import Testing
@testable import NearpaneHost

@MainActor @Suite struct UpdateRelaunchTests {
    @MainActor private final class Activity { var busy = true }

    @Test func busyDownloadCanFinishButApplyAndQuitBothNeedFreshAdmission() async throws {
        let activity = Activity()
        var invoked = 0
        let updater = ApplicationUpdater(allowNetwork: false, activityBlock: { activity.busy ? "正在录音" : nil })
        // Outside an installer cycle ordinary explicit quits retain their existing semantics.
        #expect(await updater.permitsTermination())
        updater.willRequestInstallation()
        updater.deferInstallation { invoked += 1 }
        for _ in 0..<100 where updater.status != "正在录音" { await Task.yield() }
        #expect(updater.installationDeferred && updater.status == "正在录音" && invoked == 0)
        activity.busy = false
        updater.continueInstallation()
        updater.continueInstallation()
        for _ in 0..<100 where invoked == 0 { await Task.yield() }
        #expect(invoked == 1 && !updater.installationDeferred)
        activity.busy = true
        #expect(await !updater.permitsTermination())
        activity.busy = false
        #expect(await updater.permitsTermination() && invoked == 1)
    }

    @Test func stoppingDuringAnAsynchronousAdmissionDiscardsItsInstallHandler() async throws {
        var suspended: CheckedContinuation<String?, Never>?
        var invoked = 0
        let updater = ApplicationUpdater(allowNetwork: false, activityBlock: {
            await withCheckedContinuation { suspended = $0 }
        })
        updater.deferInstallation { invoked += 1 }
        for _ in 0..<100 where suspended == nil { await Task.yield() }
        let release = try #require(suspended)
        updater.stop()
        release.resume(returning: nil)
        await Task.yield()
        #expect(invoked == 0 && !updater.installationDeferred)
    }
}
