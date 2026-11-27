import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

actor ArtworkLoader {
    private var cache: [String: Data] = [:]
    private var order: [String] = []
    private var byteCount = 0
    private let budget = 16 * 1024 * 1024
    func cached(_ key: String) -> Data? {
        guard let data = cache[key] else { return nil }
        order.removeAll { $0 == key }; order.append(key); return data
    }
    func insert(_ data: Data, key: String) {
        guard !data.isEmpty, data.count <= 8 * 1024 * 1024 else { return }
        if let old = cache.removeValue(forKey: key) { byteCount -= old.count }
        order.removeAll { $0 == key }
        while byteCount + data.count > budget || order.count >= 24 {
            guard let key = order.first else { break }
            order.removeFirst(); byteCount -= cache.removeValue(forKey: key)?.count ?? 0
        }
        cache[key] = data; order.append(key); byteCount += data.count
    }
    func clear() { cache.removeAll(); order.removeAll(); byteCount = 0 }
    static func allowedSpotifyURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return ["scdn.co", "spotifycdn.com", "spotify.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
    func downloadSpotify(_ url: URL) async throws -> Data {
        guard Self.allowedSpotifyURL(url) else { throw PlaybackError.unavailable("封面地址不受支持") }
        #if os(macOS)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.httpMaximumConnectionsPerHost = 1
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let finalURL = response.url, Self.allowedSpotifyURL(finalURL),
              response.mimeType?.hasPrefix("image/") == true,
              response.expectedContentLength <= 8 * 1024 * 1024 else { throw PlaybackError.unavailable("封面暂不可用") }
        var data = Data(); data.reserveCapacity(256 * 1024)
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 8 * 1024 * 1024 else { throw PlaybackError.outputLimit }
            data.append(byte)
        }
        return data
        #else
        throw PlaybackError.unavailable("封面下载需要 macOS 运行环境。")
        #endif
    }
}
