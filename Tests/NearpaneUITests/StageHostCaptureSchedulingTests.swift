import Dispatch
import Foundation
import Testing
@testable import NearpaneUI

@MainActor struct StageHostCaptureSchedulingTests {
    @Test(.timeLimit(.minutes(1))) func coldCaptureConstructionAllowsTheInputActorToProgress() async {
        let result = await WindowFrameStream.prepareOffActor {
            // A regression to MainActor must fail without blocking that actor.
            // Once off-main, wait for a real actor turn; parallel test work is
            // not a capture-latency measurement and has no two-second deadline.
            if Thread.isMainThread { return (progressed: false, mainThread: true) }
            let delivered = DispatchSemaphore(value: 0)
            Task { @MainActor in delivered.signal() }
            delivered.wait()
            return (progressed: true, mainThread: false)
        }
        #expect(result.progressed && !result.mainThread)
    }
}
