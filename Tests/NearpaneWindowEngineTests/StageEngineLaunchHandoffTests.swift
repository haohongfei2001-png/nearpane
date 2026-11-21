import Foundation
import NearpaneCore
@testable import NearpaneWindowEngine
import Testing

struct StageEngineLaunchHandoffTests {
    func receipt(_ flags: UInt32, owned: UInt32 = 0, home: UInt64 = 6) -> NativeStageEngineReceipt {
        .init(status:0,flags:flags,detail:0,owned:owned,nativeID:home,epoch:8,frame:.init(width:10,height:10),intent:UUID())
    }
    @Test func successfulLaunchRequiresIndependentRestorationClosureAndSlotRemovalOnThisHomeEpoch() {
        let flags: UInt32 = 64 | 8 | 32 | 256 | 512 | 1024
        func valid(_ r: NativeStageEngineReceipt) -> Bool {
            LinkedStageEngineTransport.launchConfirmed(r,expectedEpoch:8,observedEpoch:8,expectedHome:6)
        }
        #expect(valid(receipt(flags)))
        for flag: UInt32 in [64,8,32,256,512,1024] { #expect(!valid(receipt(flags & ~flag))) }
        #expect(!valid(receipt(flags|2)))
        #expect(!valid(receipt(flags|128)))
        #expect(!valid(receipt(flags,owned:1)))
        #expect(!valid(receipt(flags,home:7)))
        #expect(!LinkedStageEngineTransport.launchConfirmed(receipt(flags),expectedEpoch:8,observedEpoch:9,expectedHome:6))
    }
    @Test func cleanupIsIndependentFromHealthAndDoesNotAuthorizeNewWrites() {
        let flags: UInt32 = 32 | 256 | 512 | 1024
        #expect(LinkedStageEngineTransport.cleanupConfirmed(receipt(flags),observedEpoch:8))
        #expect(!LinkedStageEngineTransport.launchConfirmed(receipt(flags),expectedEpoch:8,observedEpoch:8,expectedHome:6))
        for flag: UInt32 in [32,256,512,1024] { #expect(!LinkedStageEngineTransport.cleanupConfirmed(receipt(flags & ~flag),observedEpoch:8)) }
        #expect(!LinkedStageEngineTransport.cleanupConfirmed(receipt(flags,owned:1),observedEpoch:8))
    }
}
