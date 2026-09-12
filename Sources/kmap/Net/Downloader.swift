import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Downloader

enum DownloadError: Error, LocalizedError {
    case badStatus(Int)
    case rangesIgnored
    case noContentLength
    case checksumMismatch(expected: String, got: String)
    case cancelled
    case io(String)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): return t("server returned HTTP %d", code)
        case .rangesIgnored: return t("server ignored the range request")
        case .noContentLength: return t("server did not report a file size")
        case .checksumMismatch(let e, let g):
            return t("MD5 mismatch — expected %1$@, got %2$@", e, g)
        case .cancelled: return t("cancelled")
        case .io(let m): return m
        }
    }
}

/// The session's delegate, forwarding to a weakly held `Downloader`.
///
/// URLSession retains its delegate until the session is invalidated, and the Downloader
/// owns the session, so a Downloader acting as its own delegate could never deinit -
/// which is where the invalidation that breaks the cycle belongs.
private final class SessionRelay: NSObject, URLSessionDataDelegate {
    // Written once, right after the Downloader's `super.init`, and only read afterwards.
    nonisolated(unsafe) weak var owner: Downloader?

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        owner?.urlSession(session, dataTask: dataTask, didReceive: data)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let owner else { return completionHandler(.cancel) }
        owner.urlSession(session, dataTask: dataTask, didReceive: response,
                         completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        owner?.urlSession(session, task: task, didCompleteWithError: error)
    }
}

final class Downloader: NSObject, URLSessionDataDelegate {

    private final class Part {
        let index: Int
        let start: Int64
        let end: Int64             // inclusive
        let url: URL
        var handle: FileHandle?
        var written: Int64 = 0
        var continuation: CheckedContinuation<Void, Error>?
        var failure: Error?

        init(index: Int, start: Int64, end: Int64, url: URL) {
            self.index = index
            self.start = start
            self.end = end
            self.url = url
        }

        var length: Int64 { end - start + 1 }
    }


    nonisolated(unsafe) let progress = DownloadProgress()
    nonisolated(unsafe) private let log: Log
    private let session: URLSession
    /// Holds the delegate callbacks. Kept so `self` can be attached after `super.init`.
    private let relay: SessionRelay
    private let lock = NSLock()
    nonisolated(unsafe) private var parts: [Int: Part] = [:]  // by URLSessionTask.taskIdentifier
    nonisolated(unsafe) private var cancelled = false

    /// Parts are joined in blocks of this size.
    private static let joinBlock = 8 << 20

    init(log: Log) {
        self.log = log
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = .day
        config.httpMaximumConnectionsPerHost = 16
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        relay = SessionRelay()
        session = URLSession(configuration: config, delegate: relay, delegateQueue: nil)
        super.init()
        relay.owner = self
    }

    deinit {
        // Frees the session, its queues and the relay. Reachable only via the relay's
        // weak reference.
        session.invalidateAndCancel()
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        session.invalidateAndCancel()
    }

    /// Synchronous: `NSLock` may not be taken from an async context.
    private func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Synchronous: `NSLock` may not be taken from an async context.
    private func register(_ part: Part, for taskID: Int) {
        lock.lock()
        parts[taskID] = part
        lock.unlock()
    }

    // MARK: Download

    /// Removes `.partN` files from downloads that will not be resumed: any part whose
    /// destination has since arrived whole and current, and any part older than `age`.
    ///
    /// - Returns: The bytes reclaimed.
    @discardableResult
    static func sweepAbandonedParts(in directory: URL, olderThan age: TimeInterval = 14 * .day,
                                    now: Date = Date()) -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return 0 }
        var freed: Int64 = 0
        var layouts: Set<URL> = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            guard let dot = name.lastIndex(of: "."),
                  name[name.index(after: dot)...].hasPrefix("part"),
                  Int(name[name.index(dot, offsetBy: 5)...]) != nil else { continue }
            let destination = url.deletingPathExtension()
            // The destination arrived since, so this part is not needed.
            var abandoned = FileManager.default.fileExists(atPath: destination.path)
                && CacheStamp.read(besides: destination) != nil
            if !abandoned {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? now
                abandoned = now.timeIntervalSince(modified) > age
            }
            guard abandoned else { continue }
            freed += FileTools.size(of: url)
            try? FileManager.default.removeItem(at: url)
            layouts.insert(destination.appendingPathExtension("layout"))
        }
        // A layout is removed with the last of its parts.
        for layout in layouts {
            let stem = layout.deletingPathExtension()
            let stillThere = (0..<Downloader.maxParts).contains {
                FileManager.default.fileExists(
                    atPath: stem.appendingPathExtension("part\($0)").path)
            }
            if !stillThere {
                freed += FileTools.size(of: layout)
                try? FileManager.default.removeItem(at: layout)
            }
        }
        return freed
    }

    /// Downloads `url` to `destination`, resuming any `.partN` files left by a previous
    /// run.
    ///
    /// - Returns: The bytes fetched over the network this time.
    @discardableResult
    func download(url: URL, to destination: URL, connections: Int) async throws -> Int64 {
        do {
            return try await download(url: url, to: destination, connections: connections,
                                      ranged: nil)
        } catch DownloadError.rangesIgnored {
            // HEAD promised ranges and GET ignored them, so the parts were laid out for
            // ranges that will not be served: start over on one connection.
            log.warn("server ignored the range request — starting over on one connection")
            for index in 0..<Downloader.maxParts {
                try? FileManager.default.removeItem(
                    at: destination.appendingPathExtension("part\(index)"))
            }
            try? FileManager.default.removeItem(at: destination.appendingPathExtension("layout"))
            return try await download(url: url, to: destination, connections: 1,
                                      ranged: false)
        }
    }

    /// - Parameter ranged: Overrides the probe's range support; nil trusts the probe.
    private func download(url: URL, to destination: URL, connections: Int,
                          ranged: Bool?) async throws -> Int64 {
        progress.setStage("probing")
        var info = try await Downloader.probeRetrying(url)
        if let ranged { info.acceptsRanges = ranged }

        let partCount = info.acceptsRanges ? max(1, min(connections, Downloader.maxParts)) : 1
        if !info.acceptsRanges && connections > 1 {
            log.warn("server will not serve byte ranges — falling back to a single connection")
        }

        Paths.ensure(destination.deletingLastPathComponent())

        // Lay out contiguous ranges.
        let chunk = info.size / Int64(partCount)
        var plan: [Part] = []
        for i in 0..<partCount {
            let start = Int64(i) * chunk
            let end = (i == partCount - 1) ? info.size - 1 : start + chunk - 1
            let partURL = destination.appendingPathExtension("part\(i)")
            plan.append(Part(index: i, start: start, end: end, url: partURL))
        }

        // Parts are resumable only by a run with the same layout: the same `.partN`
        // begins at a different byte under a different part count, and a size check
        // cannot detect it, so the layout is recorded and compared.
        let layoutFile = destination.appendingPathExtension("layout")
        let layout = "\(info.size)/\(partCount)\n"
        if (try? String(contentsOf: layoutFile, encoding: .utf8)) != layout {
            for index in 0..<Downloader.maxParts {
                try? FileManager.default.removeItem(
                    at: destination.appendingPathExtension("part\(index)"))
            }
            try? layout.write(to: layoutFile, atomically: true, encoding: .utf8)
        }

        // Whatever each part already holds is a downloaded prefix of its range.
        var alreadyOnDisk: Int64 = 0
        for part in plan {
            let existing = fileSize(part.url)
            // A part longer than its range cannot be a prefix of it.
            if existing > part.length {
                try? FileManager.default.removeItem(at: part.url)
                continue
            }
            part.written = existing
            alreadyOnDisk += existing
        }

        progress.begin(total: info.size, partTotals: plan.map(\.length), alreadyOnDisk: alreadyOnDisk)
        for part in plan { progress.seedPart(part.index, bytes: part.written) }

        if alreadyOnDisk > 0 {
            log.append("resuming — \(Fmt.bytes(alreadyOnDisk)) of \(Fmt.bytes(info.size)) already on disk")
        }
        progress.setStage("downloading")

        // Every part runs concurrently; the first failure cancels the rest.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for part in plan where part.written < part.length {
                group.addTask { [weak self] in
                    guard let self else { return }
                    try await self.fetch(part: part, from: info.finalURL, ranged: info.acceptsRanges)
                }
            }
            for try await _ in group {}
        }

        try Task.checkCancellation()

        progress.setStage("assembling")
        try assemble(plan, into: destination, expectedSize: info.size)
        try? FileManager.default.removeItem(at: layoutFile)
        return info.size - alreadyOnDisk
    }

    /// Consecutive retries allowed per part. Any byte that arrives resets the count, so
    /// this bounds a dead connection rather than a slow one.
    private static let retriesPerPart = 8

    /// The most parts one file is cut into, and so the most `.partN` files a run can
    /// leave behind.
    static let maxParts = 16

    /// Whether `error` is transient: a 5xx status, or a connection-level `URLError`. A
    /// 4xx, a checksum failure, a full disk and a cancellation are all final.
    static func worthRetrying(_ error: Error) -> Bool {
        if case DownloadError.badStatus(let code) = error { return (500...599).contains(code) }
        guard let url = error as? URLError else { return false }
        switch url.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
             .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable,
             .badServerResponse, .zeroByteResource:
            return true
        default:
            return false
        }
    }

    /// Fetches one part, resuming where it stopped for as long as it makes progress.
    private func fetch(part: Part, from url: URL, ranged: Bool) async throws {
        var failures = 0
        while true {
            let before = part.written
            do {
                try await attempt(part: part, from: url, ranged: ranged)
                return
            } catch {
                if Task.isCancelled { throw error }
                // Bytes arrived before the drop, so the count starts again.
                if part.written > before { failures = 0 }
                // Retrying without ranges would append a second copy from the top.
                guard ranged, part.written < part.length,
                      failures < Self.retriesPerPart, Self.worthRetrying(error) else { throw error }
                failures += 1
                if failures == 1 {
                    log.warn("connection dropped with \(Fmt.bytes(part.length - part.written))"
                             + " left of part \(part.index + 1) — picking it up again")
                }
                part.failure = nil
                // Exponential backoff, capped at eight seconds.
                try await Task.sleep(nanoseconds: UInt64(min(8, 1 << failures)) * 1_000_000_000)
            }
        }
    }

    private func attempt(part: Part, from url: URL, ranged: Bool) async throws {
        // A retry sleep can end after `cancel()` invalidated the session, and a task
        // made on a dead session never completes.
        if isCancelled() { throw DownloadError.cancelled }
        var request = URLRequest(url: url)
        if ranged {
            let from = part.start + part.written
            request.setValue("bytes=\(from)-\(part.end)", forHTTPHeaderField: "Range")
        }

        Paths.ensure(part.url.deletingLastPathComponent())
        if !FileManager.default.fileExists(atPath: part.url.path) {
            _ = FileManager.default.createFile(atPath: part.url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: part.url)
        try handle.seekToEnd()
        part.handle = handle

        let task = session.dataTask(with: request)
        register(part, for: task.taskIdentifier)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                part.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Concatenates the part files into `destination`, checks the size and removes them.
    ///
    /// - Throws: `DownloadError.io` if the result is not `expectedSize` bytes.
    private func assemble(_ plan: [Part], into destination: URL, expectedSize: Int64) throws {
        // A single part is moved into place.
        if plan.count == 1 {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: plan[0].url, to: destination)
            return
        }

        try? FileManager.default.removeItem(at: destination)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw DownloadError.io("could not create \(destination.lastPathComponent)")
        }
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }

        for part in plan.sorted(by: { $0.index < $1.index }) {
            let input = try FileHandle(forReadingFrom: part.url)
            defer { try? input.close() }
            while let block = try input.read(upToCount: Self.joinBlock), !block.isEmpty {
                try out.write(contentsOf: block)
            }
        }
        try out.close()

        let finalSize = fileSize(destination)
        guard finalSize == expectedSize else {
            throw DownloadError.io("assembled \(Fmt.bytes(finalSize)), expected \(Fmt.bytes(expectedSize))")
        }
        for part in plan { try? FileManager.default.removeItem(at: part.url) }
    }

    private func fileSize(_ url: URL) -> Int64 { FileTools.size(of: url) }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let part = parts[dataTask.taskIdentifier]
        lock.unlock()
        guard let part, let handle = part.handle else { return }
        do {
            try handle.write(contentsOf: data)
            part.written += Int64(data.count)
            progress.advance(part: part.index, by: Int64(data.count))
        } catch {
            part.failure = DownloadError.io(error.localizedDescription)
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            if !(200...299).contains(http.statusCode) {
                lock.lock()
                let part = parts[dataTask.taskIdentifier]
                lock.unlock()
                part?.failure = DownloadError.badStatus(http.statusCode)
                completionHandler(.cancel)
                return
            }
            // A ranged request answered 200 sends the whole file; appending it would
            // make an oversized part, so it is refused before the transfer.
            if http.statusCode == 200,
               dataTask.originalRequest?.value(forHTTPHeaderField: "Range") != nil {
                lock.lock()
                let part = parts[dataTask.taskIdentifier]
                lock.unlock()
                part?.failure = DownloadError.rangesIgnored
                completionHandler(.cancel)
                return
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let part = parts.removeValue(forKey: task.taskIdentifier)
        let wasCancelled = cancelled
        lock.unlock()
        guard let part else { return }

        try? part.handle?.close()
        part.handle = nil

        let continuation = part.continuation
        part.continuation = nil

        if let failure = part.failure {
            continuation?.resume(throwing: failure)
        } else if let error {
            continuation?.resume(throwing: wasCancelled ? DownloadError.cancelled : error)
        } else {
            continuation?.resume()
        }
    }
}
