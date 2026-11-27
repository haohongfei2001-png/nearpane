import Dispatch
import Foundation
import Testing
@testable import NearpaneUI

@MainActor struct StageHostCaptureSchedulingTests {
    @Test func coldCaptureConstructionAllowsTheInputActorToProgress() async {
        let result = await WindowFrameStream.prepareOffActor {
            let delivered = DispatchSemaphore(value: 0)
            Task { @MainActor in delivered.signal() }
            let progressed = delivered.wait(timeout: .now() + 2) == .success
            return (progressed: progressed, mainThread: Thread.isMainThread)
        }
        #expect(result.progressed && !result.mainThread)
    }
}
