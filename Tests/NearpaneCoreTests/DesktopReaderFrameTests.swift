import Foundation
import Testing
@testable import NearpaneCore

struct DesktopReaderFrameTests {
    @Test func frameHasPortableBoundedNetworkLength() throws {
        #expect(try DesktopReaderFrame.header(length: 8192, limit: 8192) == Data([0, 0, 32, 0]))
        #expect(try DesktopReaderFrame.length(Data([0, 16, 0, 0]), limit: 1_048_576) == 1_048_576)
        for size in [-1, 0, 8193] {
            #expect(throws: (any Error).self) { try DesktopReaderFrame.header(length: size, limit: 8192) }
        }
        for header in [Data(), Data([0, 1]), Data([0, 0, 0, 0]), Data([255, 255, 255, 255])] {
            #expect(throws: (any Error).self) { try DesktopReaderFrame.length(header, limit: 1_048_576) }
        }
    }
}
