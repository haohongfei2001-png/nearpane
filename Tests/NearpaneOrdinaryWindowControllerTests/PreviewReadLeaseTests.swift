import Darwin
import NearpaneCore
@testable import NearpaneOrdinaryWindowController
import Testing

struct PreviewReadLeaseTests {
    @Test func workerRejectsMutationsAndOtherNumbersBeforeConsultingWindowServer() {
        let worker = Worker(getppid(), previewWindow: 48)
        for action: OrdinaryWindowRequest.Action in [.write, .acknowledgeBoundary, .watchCreated, .takeCreated, .endCreated] {
            let request = OrdinaryWindowRequest(action, pid: -1, launch: 1, bundle: "fixture")
            #expect(worker.handle(request).failure == "此通道仅核对已选预览窗口。")
        }
        let other = ManagedWindowID(pid: 2, launch: 4, number: 49, element: .init())
        let read = OrdinaryWindowRequest(.prepare, pid: 2, launch: 4, bundle: "fixture", id: other)
        #expect(worker.handle(read).failure == "此通道仅核对已选预览窗口。")
        #expect(worker.app == nil && worker.windowsByID.isEmpty)
    }
}
