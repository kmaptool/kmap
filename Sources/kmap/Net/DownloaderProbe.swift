import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Asking a server about a file without fetching it, and checking what arrived:
/// the HEAD probe, and the MD5 the mirror publishes beside every extract.
extension Downloader {
    struct RemoteInfo {
        let finalURL: URL
        let size: Int64
        var acceptsRanges: Bool
        let lastModified: String?
    }

    /// `probe`, retried up to three times with exponential backoff for the errors
    /// `worthRetrying` accepts.
    static func probeRetrying(_ url: URL) async throws -> RemoteInfo {
        var failures = 0
        while true {
            do {
                return try await probe(url)
            } catch {
                if Task.isCancelled { throw error }
                guard failures < 3, worthRetrying(error) else { throw error }
                failures += 1
                try await Task.sleep(nanoseconds: UInt64(1 << failures) * 1_000_000_000)
            }
        }
    }

    /// Sends a HEAD request, following redirects, for the final URL, size, range
    /// support and `Last-Modified`.
    ///
    /// - Throws: `DownloadError.badStatus`, `.noContentLength`, or `.io`.
    static func probe(_ url: URL) async throws -> RemoteInfo {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 45
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DownloadError.io("no HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw DownloadError.badStatus(http.statusCode)
        }
        let size = http.expectedContentLength
        guard size > 0 else { throw DownloadError.noContentLength }
        let ranges = (http.value(forHTTPHeaderField: "Accept-Ranges") ?? "").lowercased().contains("bytes")
        return RemoteInfo(finalURL: http.url ?? url,
                          size: size,
                          acceptsRanges: ranges,
                          lastModified: http.value(forHTTPHeaderField: "Last-Modified"))
    }

    /// Streams `url` through MD5 in 8 MB blocks, so no whole file is held in memory.
    ///
    /// The next block is read on another queue while the current one is hashed, since
    /// MD5 itself cannot be parallelised.
    static func md5(of url: URL, progress: ((Double) -> Void)? = nil) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let total = Double(FileTools.size(of: url))
        var hasher = MD5()
        var done: Double = 0
        let chunk = 8 * 1024 * 1024

        /// Where the reading queue leaves its block. Access alternates between the two
        /// threads, ordered by the semaphore below.
        final class Handoff: @unchecked Sendable {
            var block: Data?
            var failure: Error?
        }
        let queue = DispatchQueue(label: "kmap.md5.read")
        let handoff = Handoff()

        var current = try handle.read(upToCount: chunk)
        while let block = current, !block.isEmpty {
            let ready = DispatchSemaphore(value: 0)
            queue.async {
                do { handoff.block = try handle.read(upToCount: chunk) }
                catch { handoff.failure = error }
                ready.signal()
            }
            hasher.update(block)
            done += Double(block.count)
            if total > 0 { progress?(done / total) }
            ready.wait()
            if let failure = handoff.failure { throw failure }
            current = handoff.block
        }
        return hasher.finalizeHex()
    }

    /// Fetches an `.md5` file, whose format is "<hash>  <filename>", and returns the
    /// lowercased hash, or nil where it is missing or malformed.
    static func fetchExpectedMD5(_ url: URL) async -> String? {
        guard let text = await Fetch.text(url) else { return nil }
        let token = text.split(separator: " ").first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token, token.count == 32,
              token.allSatisfy({ $0.isHexDigit }) else { return nil }
        return token.lowercased()
    }
}
