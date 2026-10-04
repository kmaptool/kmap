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

        var length: Int64 { end - start + 1 }

        /// Bytes of the range already on disk.
        var written: Int64 { FileTools.size(of: url) }
    }

    /// Per request; a whole resource may take a day.
    static let requestTimeout: TimeInterval = 60

    private let session: URLSession
    private let receiver: Receiver

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
        session.invalidateAndCancel()
    }

    var isCancelled: Bool { receiver.isCancelled }

    /// Whether a `Content-Range` ("bytes 100-199/1000") starts where the `Range` asked
    /// ("bytes=100-199" or "bytes=100-"). An answer it cannot read is taken on trust.
    static func serves(_ contentRange: String, asked range: String) -> Bool {
        func start(_ text: Substring) -> Int64? { Int64(text.prefix { $0.isNumber }) }
        guard let askedFrom = range.split(separator: "=").last.flatMap(start),
            let servedFrom = contentRange.split(separator: " ").last.flatMap(start)
        else { return true }
        return askedFrom == servedFrom
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

        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Known to the receiver before the first byte can arrive.
                receiver.expect(task, part: part.index, into: handle, resuming: continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}
