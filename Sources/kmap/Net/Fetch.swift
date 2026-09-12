import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The small fetches: one GET, one timeout, the body on a 2xx and an error otherwise.
/// Files go through `Downloader`; this is for indexes, lists, checksums and outlines.
enum Fetch {
    static let timeout: TimeInterval = 30

    /// The body at `url`. A status outside 2xx throws `DownloadError.badStatus`.
    static func data(_ url: URL, timeout: TimeInterval = timeout) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw DownloadError.badStatus(http.statusCode)
        }
        return data
    }

    /// The body as UTF-8 text, or nil where anything went wrong.
    static func text(_ url: URL, timeout: TimeInterval = timeout) async -> String? {
        guard let data = try? await data(url, timeout: timeout) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
