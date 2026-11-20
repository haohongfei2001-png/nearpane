import CNativeSpaceActions
import CoreGraphics
import Foundation
import Testing

struct DockGestureTests {
    @Test func versionFamiliesAreExplicit() {
        #expect(NPDockProtocolForVersion(26, 5) == NPDockUnsupported)
        #expect(NPDockProtocolForVersion(26, 6) == NPDockLowTravel26)
        #expect(NPDockProtocolForVersion(26, 7) == NPDockLowTravel26)
        #expect(NPDockProtocolForVersion(27, 0) == NPDockSerialized27)
        #expect(NPDockProtocolForVersion(27, 1) == NPDockUnsupported)
        #expect(NPDockProtocolForVersion(28, 0) == NPDockUnsupported)
    }

    @Test(arguments: [true, false], [true, false])
    func modernWireFieldsAndPayload(right: Bool, natural: Bool) throws {
        for phase: Int32 in [1, 2, 4] {
            let event = try #require(NPDockCopySwipeEvent(NPDockSerialized27, right, natural, phase, CGPoint(x: 20, y: 30), 987654))
            let companion = try #require(NPDockCopyCompanion(NPDockSerialized27, CGPoint(x: 20, y: 30), 987654))
            #expect(companion.getIntegerValueField(CGEventField(rawValue: 55)!) == 29 && companion.timestamp == 987654)
            let sign: Int64 = right == natural ? -1 : 1
            func number(_ field: UInt32) -> Int64 { event.getIntegerValueField(CGEventField(rawValue: field)!) }
            func scalar(_ field: UInt32) -> Double { event.getDoubleValueField(CGEventField(rawValue: field)!) }
            #expect(number(55) == 30 && number(110) == 23 && number(123) == 1)
            #expect(number(132) == phase && number(134) == phase)
            #expect(abs(scalar(124) - Double(sign) * 0.000016) < 0.00000001)
            #expect(scalar(129) == Double(phase == 4 ? sign * 9999 : 0))
            // Read the OS round-tripped wire record, including its tagged little-endian IOHID payload.
            let bytes = try #require(event.data as Data?)
            let size = phase == 4 ? 96 : 68
            let tag = Data([0, UInt8(size), 0x10, 0x6d])
            let payload = try #require(bytes.range(of: tag)).upperBound
            #expect(bytes.count >= payload + size)
            func le32(_ offset: Int) -> UInt32 {
                bytes.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: payload + offset, as: UInt32.self)) }
            }
            #expect(le32(24) == (phase == 4 ? 2 : 1))
            #expect(le32(28) == 40 && le32(32) == 23)
            #expect(le32(36) == UInt32(phase) << 24)
            #expect(Int32(bitPattern: le32(64)) == Int32(sign))
            if phase == 4 {
                #expect(le32(68) == 28 && le32(72) == 9)
                #expect(Int32(bitPattern: le32(84)) == Int32(sign * 9999 * 65536))
            }
        }
    }

    @Test func olderProtocolHasNoModernPayloadOrCompanionVelocityConvention() throws {
        #expect(NPDockCopyCompanion(NPDockLowTravel26, .zero, 7) == nil)
        #expect(NPDockCopySwipeEvent(NPDockUnsupported, true, true, 1, .zero, 7) == nil)
        #expect(NPDockCopySwipeEvent(NPDockSerialized27, true, true, 8, .zero, 7) == nil)
        for right in [false, true] {
            let event = try #require(NPDockCopySwipeEvent(NPDockLowTravel26, right, true, 1, .zero, 7))
            #expect(abs(event.getDoubleValueField(CGEventField(rawValue: 124)!) - (right ? 0.0001 : -0.0001)) < 1e-7)
            #expect(event.getDoubleValueField(CGEventField(rawValue: 129)!) == (right ? 2000 : -2000))
        }
    }
}
