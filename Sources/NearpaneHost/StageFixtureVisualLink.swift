#if DEBUG || NP_PRODUCT_CORNER_MATERIAL
import Darwin
import Foundation
import Security

/// Private one-shot control channel. Only the signed test window can be named and no pixels travel on this link.
enum StageFixtureVisualLink {
    struct Pin: Codable {
        let pid: Int32, cdhash: String
    }
    struct Request: Codable, Equatable, Sendable {
        let session, challenge, display, space: UUID
        let native, birth, began: UInt64
        let window: UInt32, pid: Int32, cdhash: String
    }
    struct Sample: Codable, Sendable {
        let time: UInt64, matchingStripes: Int
        var opaqueCells: Int?, greenCells: Int?, magentaCells: Int?
    }
    struct DisplayMarker: Codable, Sendable {
        let status, reason: String
        let samples: [Sample]
    }
    struct Reply: Codable, Sendable {
        let request: Request, observerPID: Int32, screenAccess: Bool
        let samples: [Sample], status, reason: String
        var displayMarker: DisplayMarker?

        private func matchesTwice(_ reads: [Sample], until: UInt64) -> Bool {
            reads.count == 2 && request.began < reads[0].time && reads[0].time < reads[1].time &&
                reads[1].time <= until && reads[1].time - reads[0].time >= 50_000_000 &&
                reads.allSatisfy { $0.matchingStripes == 16 }
        }
        func confirms(_ expected: Request, observer: Int32, until: UInt64) -> Bool {
            request == expected && expected.session != expected.challenge && observerPID == observer &&
                status == "PASS" && reason == "registeredFixturePixelsTwice" && screenAccess &&
                until >= expected.began && until - expected.began < 8_000_000_000 && matchesTwice(samples, until: until)
        }
        func displayStatus(_ expected: Request, observer: Int32, until: UInt64) -> String {
            guard confirms(expected, observer: observer, until: until), let marker = displayMarker else { return "UNKNOWN" }
            guard marker.status == "PASS" else { return marker.status == "FAIL" ? "FAIL" : "UNKNOWN" }
            guard marker.reason == "displayMarkerUnobstructedTwice", matchesTwice(marker.samples, until: until),
                  zip(samples, marker.samples).allSatisfy({ $0.time < $1.time }),
                  marker.samples[0].time < samples[1].time,
                  marker.samples.allSatisfy({ $0.opaqueCells == 16 }) else { return "UNKNOWN" }
            return "PASS"
        }
    }
    enum Fault: String, Error { case endpoint, untrustedPeer, terminal, stale, frame }
    static let observerID = "net.example.nearpane.p2-observer", hostID = "com.holdsnow.nearpane.host"
    static let fixtureID = "com.holdsnow.nearpane.engine-fixture.a"

    static func birth(_ pid: Int32) -> UInt64? {
        var b = proc_bsdinfo()
        guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &b, Int32(MemoryLayout.size(ofValue: b))) == MemoryLayout.size(ofValue: b),
              b.pbi_pid == UInt32(pid), b.pbi_uid == getuid() else { return nil }
        return b.pbi_start_tvsec * 1_000_000 + b.pbi_start_tvusec
    }
    static func signer(_ attributes: [String: Any], _ identifier: String) throws -> String {
        var guest: SecCode?, image: SecStaticCode?, requirement: SecRequirement?, info: CFDictionary?
        let rule = "anchor apple generic and identifier \"\(identifier)\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"ZB9D4T66QB\""
        guard [observerID, hostID, fixtureID].contains(identifier),
              SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &guest) == errSecSuccess, let guest,
              SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecCodeCheckValidity(guest, .init(rawValue:kSecCSStrictValidate), requirement) == errSecSuccess,
              SecCodeCopyStaticCode(guest, [], &image) == errSecSuccess, let image,
              SecCodeCopySigningInformation(image, .init(rawValue:kSecCSSigningInformation), &info) == errSecSuccess,
              let hash = (info as? [String:Any])?[kSecCodeInfoUnique as String] as? Data, hash.count == 20 else { throw Fault.untrustedPeer }
        return hash.map { String(format:"%02x",$0) }.joined()
    }
    static func peer(_ fd: Int32, identifier: String) throws -> Pin {
        var token = audit_token_t(), size = socklen_t(MemoryLayout<audit_token_t>.size)
        var login: SecuritySessionId = 0
        guard SessionGetInfo(callerSecuritySession, &login, nil) == errSecSuccess, login != 0,
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0, size == MemoryLayout<audit_token_t>.size,
              token.val.1 == getuid(), token.val.6 == login, token.val.5 > 1, token.val.5 <= UInt32(Int32.max) else { throw Fault.untrustedPeer }
        let hash = try signer([kSecGuestAttributeAudit as String: withUnsafeBytes(of:&token) { Data($0) }], identifier)
        return .init(pid: Int32(token.val.5), cdhash: hash)
    }

    static func path(_ nonce: UUID) throws -> String {
        let dir = "/private/tmp/nearpane-host-scope." + nonce.uuidString.lowercased()
        var s = stat()
        guard getuid() != 0, getuid() == geteuid(), lstat(dir, &s) == 0, s.st_uid == getuid(),
              s.st_mode & S_IFMT == S_IFDIR, s.st_mode & 0o777 == 0o700 else { throw Fault.endpoint }
        return dir + "/visual.sock"
    }
    static func address(_ path: String, _ operation: (UnsafePointer<sockaddr>, socklen_t) -> Int32) throws {
        var addr = sockaddr_un()
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { throw Fault.endpoint }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of:&addr.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern:$0) }) }
        let rc = withUnsafePointer(to:&addr) { $0.withMemoryRebound(to:sockaddr.self, capacity:1) {
            operation($0, socklen_t(MemoryLayout<sockaddr_un>.size))
        } }
        if rc != 0 { throw Fault.endpoint }
    }
    static func configure(_ fd: Int32) throws {
        var yes: Int32 = 1, limit = timeval(tv_sec: 5, tv_usec: 0)
        guard fd >= 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,socklen_t(MemoryLayout.size(ofValue:yes))) == 0,
              setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&limit,socklen_t(MemoryLayout.size(ofValue:limit))) == 0,
              setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&limit,socklen_t(MemoryLayout.size(ofValue:limit))) == 0 else { throw Fault.endpoint }
    }
    // A single length-bounded record in each direction. The peer must close its writing half.
    static func send<T: Encodable>(_ value: T, to fd: Int32) throws {
        let data = try JSONEncoder().encode(value)
        guard !data.isEmpty, data.count <= 2048 else { throw Fault.terminal }
        try data.withUnsafeBytes { buf in
            var offset = 0
            while offset < buf.count {
                let n = Darwin.write(fd,buf.baseAddress!.advanced(by:offset),buf.count-offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw Fault.terminal }
                offset += n
            }
        }
        guard shutdown(fd, SHUT_WR) == 0 else { throw Fault.terminal }
    }
    static func receive<T: Decodable>(_ type: T.Type, from fd: Int32) throws -> T {
        var data = Data(), block = [UInt8](repeating:0,count:512)
        let until = DispatchTime.now().uptimeNanoseconds + 7_000_000_000
        while data.count <= 2048 && DispatchTime.now().uptimeNanoseconds < until {
            let n = Darwin.read(fd,&block,block.count)
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { throw Fault.terminal }
            if n == 0 { return try JSONDecoder().decode(type,from:data) }
            data.append(contentsOf:block.prefix(n))
        }
        throw Fault.terminal
    }
    static func request(_ item: Request, from pin: Pin) throws -> Reply {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Fault.endpoint }
        defer { close(fd) }
        try configure(fd)
        try address(path(item.session)) { Darwin.connect(fd,$0,$1) }
        let identity = try peer(fd,identifier:observerID)
        guard pin.pid == identity.pid, pin.cdhash == identity.cdhash else { throw Fault.untrustedPeer }
        try send(item,to:fd)
        let reply = try receive(Reply.self,from:fd)
        guard reply.request == item, reply.observerPID == identity.pid else { throw Fault.untrustedPeer }
        return reply
    }
}
#endif
