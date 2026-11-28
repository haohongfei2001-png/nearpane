import Foundation
import LyricCore

public struct LyricsHTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data
    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
        self.body = body
    }
}

public protocol LyricsHTTPTransport: Sendable {
    func get(_ request: URLRequest) async throws -> LyricsHTTPResponse
}

public struct URLSessionLyricsTransport: LyricsHTTPTransport {
    private let session: URLSession
    private let maximumResponseBytes: Int
    public init(maximumResponseBytes: Int = 8 * 1024 * 1024) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        self.session = URLSession(configuration: configuration)
        self.maximumResponseBytes = max(1, maximumResponseBytes)
    }
    public func get(_ request: URLRequest) async throws -> LyricsHTTPResponse {
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, response.url?.scheme == "https" else {
            throw LyricDomain.SourceFailure.transportUnavailable
        }
        guard response.expectedContentLength <= Int64(maximumResponseBytes) else {
            throw invalid("The lyric service response is too large.")
        }
        var data = Data()
        data.reserveCapacity(min(maximumResponseBytes, max(0, Int(response.expectedContentLength))))
        for try await byte in bytes {
            if data.count & 0x3fff == 0 { try Task.checkCancellation() }
            guard data.count < maximumResponseBytes else { throw invalid("The lyric service response is too large.") }
            data.append(byte)
        }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { output, entry in
            if let key = entry.key as? String { output[key.lowercased()] = String(describing: entry.value) }
        }
        return .init(status: http.statusCode, headers: headers, body: data)
    }
}

/// Actors re-enter at await; this gate guarantees only one network transfer per provider.
actor LyricsRequestGate {
    private var held = false
    private var waiters: [(UUID, CheckedContinuation<Void, any Error>)] = []
    func acquire() async throws {
        try Task.checkCancellation()
        if !held { held = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        do { try Task.checkCancellation() }
        catch { release(); throw error }
    }
    func release() {
        if waiters.isEmpty { held = false }
        else { waiters.removeFirst().1.resume() }
    }
    private func cancel(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.0 == id }) {
            waiters.remove(at: index).1.resume(throwing: CancellationError())
        }
    }
}
