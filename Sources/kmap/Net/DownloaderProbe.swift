import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Asking a server about a file without fetching it, and checking what arrived: the HEAD
/// probe, and the MD5 the mirror publishes beside every extract.
extension Downloader {
    struct RemoteInfo {
        let finalURL: URL
        let size: Int64
        var acceptsRanges: Bool
        let lastModified: String?
    }

    private static let probeTimeout: TimeInterval = 45
    private static let probeRetries = 3

    /// Files are hashed in blocks of this size.
    private static let hashBlock = 8 << 20

    /// `probe`, retried with backoff for the errors `worthRetrying` accepts.
    static func probeRetrying(_ url: URL) async throws -> RemoteInfo {
        try await retrying { try await probe(url) }
    }

    /// Runs `body` again, after a growing pause, for as long as it fails with something
    /// transient: a timeout, a dropped connection, a 5xx. Three more tries, then the last
    /// error. One HEAD among several sent at once can be the one the mirror drops, and
    /// that must not read as the server being down.
    static func retrying<T>(
        attempts: Int = probeRetries,
        pause: (Int) async throws -> Void = backOff,
        _ body: () async throws -> T
    ) async throws -> T {
        var failures = 0
        while true {
            do {
                return try await body()
            } catch {
                if Task.isCancelled { throw error }
                guard failures < attempts, worthRetrying(error) else { throw error }
                failures += 1
                try await pause(failures)
            }
        }
    }

    /// Sends a HEAD request, following redirects, for the final URL, size, range support
    /// and `Last-Modified`.
    ///
    /// - Throws: `DownloadError.badStatus`, `.noContentLength`, or `.io`.
    static func probe(_ url: URL) async throws -> RemoteInfo {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = probeTimeout
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
        return RemoteInfo(
            finalURL: http.url ?? url,
            size: size,
            acceptsRanges: ranges,
            lastModified: http.value(forHTTPHeaderField: "Last-Modified")
        )
    }

    /// Streams `url` through MD5 block by block, so no whole file is held in memory. The
    /// next block is read on another queue while the current one is hashed.
    /// `shouldStop` is asked between blocks: a multi-gigabyte extract takes minutes to
    /// hash, and Ctrl+C must not wait for the end of it.
    static func md5(
        of url: URL,
        shouldStop: () -> Bool = { false },
        progress: ((Double) -> Void)? = nil
    ) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let total = Double(FileTools.size(of: url))
        var hasher = MD5()
        var done: Double = 0

        /// Where the reading queue leaves its block. The two threads take turns, ordered
        /// by the semaphore below.
        final class Handoff: @unchecked Sendable {
            var block: Data?
            var failure: Error?
        }
        let queue = DispatchQueue(label: "kmap.md5.read")
        let handoff = Handoff()

        var current = try handle.read(upToCount: hashBlock)
        while let block = current, !block.isEmpty {
            let ready = DispatchSemaphore(value: 0)
            queue.async {
                do { handoff.block = try handle.read(upToCount: hashBlock) } catch { handoff.failure = error }
                ready.signal()
            }
            hasher.update(block)
            done += Double(block.count)
            if total > 0 { progress?(done / total) }
            ready.wait()
            if shouldStop() { throw CancellationError() }
            if let failure = handoff.failure { throw failure }
            current = handoff.block
        }
        return hasher.finalizeHex()
    }

    /// Fetches an `.md5` file, "<hash>  <filename>", and returns the lowercased hash, or
    /// nil where it is missing or malformed.
    static func fetchExpectedMD5(_ url: URL) async -> String? {
        // Retried like the probe: a missed .md5 costs a whole extract read or refetch.
        let data = try? await retrying { try await Fetch.data(url, timeout: probeTimeout) }
        guard let data, let text = String(data: data, encoding: .utf8) else { return nil }
        let token = text.split(separator: " ").first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token, token.count == 32,
            token.allSatisfy({ $0.isHexDigit })
        else { return nil }
        return token.lowercased()
    }
}
