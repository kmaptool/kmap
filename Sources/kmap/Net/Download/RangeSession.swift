import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One URLSession streaming byte ranges into part files. Each part is one data task:
/// bytes go to the part's file as they arrive, and the awaiting caller resumes when the
/// task ends.
///
/// The part's file is the record of how far it has got: a request picks up at the file's
/// length, and nothing else keeps count.
final class RangeSession: Sendable {
    /// One range of the file and where it is kept.
    struct Part: Sendable {
        let index: Int
        let start: Int64
        let end: Int64  // inclusive
        let url: URL
        /// The whole file's size, where known: a range of a file of another size is of
        /// another file, one replaced on the server since the download began.
        var total: Int64? = nil

        var length: Int64 { end - start + 1 }

        /// Bytes of the range already on disk.
        var written: Int64 { FileTools.size(of: url) }
    }

    /// Per request; a whole resource may take a day.
    static let requestTimeout: TimeInterval = 60

    private let session: URLSession
    private let receiver: Receiver
    /// True once the session is invalidated. A task is made under the same lock, since one
    /// made on a dead session aborts the process.
    private let invalidated = Locked(false)

    init(progress: DownloadProgress) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Self.requestTimeout
        config.timeoutIntervalForResource = .day
        config.httpMaximumConnectionsPerHost = PartFiles.maxParts
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        receiver = Receiver(progress: progress)
        session = URLSession(configuration: config, delegate: receiver, delegateQueue: nil)
    }

    deinit {
        // URLSession keeps its delegate until invalidated; this frees both and the queues.
        session.invalidateAndCancel()
    }

    func cancel() {
        receiver.markCancelled()
        invalidated.withLock { dead in
            dead = true
            session.invalidateAndCancel()
        }
    }

    var isCancelled: Bool { receiver.isCancelled }

    /// Whether a `Content-Range` ("bytes 100-199/1000") is the `Range` asked ("bytes=100-199"
    /// or "bytes=100-"): it starts there, ends no later, and is of a file of `total` bytes.
    /// An answer it cannot read is taken on trust.
    static func serves(_ contentRange: String, asked range: String, total: Int64? = nil) -> Bool {
        func bounds(_ text: Substring?) -> (from: Int64?, to: Int64?) {
            guard let text else { return (nil, nil) }
            let ends = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            return (ends.first.flatMap { Int64($0) }, ends.count > 1 ? Int64(ends[1]) : nil)
        }
        let asked = bounds(range.split(separator: "=").last)
        guard let servedText = contentRange.split(separator: " ").last else { return true }
        let halves = servedText.split(separator: "/", maxSplits: 1)
        let served = bounds(halves.first)
        guard let askedFrom = asked.from, let servedFrom = served.from else { return true }
        if askedFrom != servedFrom { return false }
        if let askedTo = asked.to, let servedTo = served.to, servedTo > askedTo { return false }
        if let total, halves.count > 1, let servedTotal = Int64(halves[1]), servedTotal != total { return false }
        return true
    }

    /// Fetches what is left of `part` in one request, appending to its file. Without
    /// ranges the server sends the file from the top, so the part starts over.
    func fetch(_ part: Part, from url: URL, ranged: Bool) async throws {
        // A retry sleep can end after `cancel()` invalidated the session, and a task made
        // on a dead session never completes.
        if isCancelled { throw DownloadError.cancelled }
        try Network.ensureOpen()
        var request = URLRequest(url: url)
        if ranged {
            request.setValue(
                "bytes=\(part.start + part.written)-\(part.end)",
                forHTTPHeaderField: "Range"
            )
        } else {
            FileTools.removeIfPresent(part.url)
        }

        Paths.ensure(part.url.deletingLastPathComponent())
        let handle = try FileTools.openForWriting(part.url)

        guard let task = invalidated.withLock({ dead in dead ? nil : session.dataTask(with: request) }) else {
            try? handle.close()
            throw DownloadError.cancelled
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Known to the receiver before the first byte can arrive.
                receiver.expect(task, part: part.index, total: part.total, into: handle, resuming: continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}
