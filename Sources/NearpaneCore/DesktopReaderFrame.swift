import Foundation

/// A bounded message on the overview helper's private anonymous pipes. A fresh
/// DesktopReadRequest and DesktopSnapshot remain the payload for every exchange.
package enum DesktopReaderFrame {
    package static let requestLimit = 8_192
    package static let responseLimit = 1_048_576
    package enum Failure: Error { case invalidLength }

    package static func header(length: Int, limit: Int) throws -> Data {
        guard length > 0, length <= limit, let value = UInt32(exactly: length) else { throw Failure.invalidLength }
        return Data([UInt8((value >> 24) & 255), UInt8((value >> 16) & 255),
                     UInt8((value >> 8) & 255), UInt8(value & 255)])
    }

    package static func length(_ header: Data, limit: Int) throws -> Int {
        guard header.count == 4, limit > 0 else { throw Failure.invalidLength }
        let value = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard value > 0, UInt64(value) <= UInt64(limit) else { throw Failure.invalidLength }
        return Int(value)
    }
}
