import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One URLSession streaming byte ranges into part files. Each part is one data task:
/// bytes go to the part's file as they arrive, and the awaiting caller resumes when the
/// task ends.
final class RangeSession {

    /// One range of the file and how far it has been fetched.
    final class Part {
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

    /// Per request; a whole resource may take a day.
    static let requestTimeout: TimeInterval = 60

    nonisolated(unsafe) private let progress: DownloadProgress
    private let session: URLSession
    private let relay: Relay
    private let lock = NSLock()
    nonisolated(unsafe) private var parts: [Int: Part] = [:]  // by URLSessionTask.taskIdentifier
    nonisolated(unsafe) private var cancelled = false

    init(progress: DownloadProgress) {
        self.progress = progress
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Self.requestTimeout
        config.timeoutIntervalForResource = .day
        config.httpMaximumConnectionsPerHost = PartFiles.maxParts
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        relay = Relay()
        session = URLSession(configuration: config, delegate: relay, delegateQueue: nil)
        relay.owner = self
    }

    deinit {
        // Frees the session, its queues and the relay.
        session.invalidateAndCancel()
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        session.invalidateAndCancel()
    }

    /// Synchronous: `NSLock` may not be taken from an async context.
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Fetches what is left of `part` in one request, appending to its file.
    func fetch(_ part: Part, from url: URL, ranged: Bool) async throws {
        // A retry sleep can end after `cancel()` invalidated the session, and a task made
        // on a dead session never completes.
        if isCancelled { throw DownloadError.cancelled }
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

    /// Synchronous: `NSLock` may not be taken from an async context.
    private func register(_ part: Part, for taskID: Int) {
        lock.lock()
        parts[taskID] = part
        lock.unlock()
    }

    // MARK: Delegate side

    private func part(of taskID: Int) -> Part? {
        lock.lock()
        defer { lock.unlock() }
        return parts[taskID]
    }

    fileprivate func received(_ data: Data, for task: URLSessionDataTask) {
        guard let part = part(of: task.taskIdentifier), let handle = part.handle else { return }
        do {
            try handle.write(contentsOf: data)
            part.written += Int64(data.count)
            progress.advance(part: part.index, by: Int64(data.count))
        } catch {
            part.failure = DownloadError.io(error.localizedDescription)
            task.cancel()
        }
    }

    fileprivate func disposition(of response: URLResponse,
                                 for task: URLSessionDataTask) -> URLSession.ResponseDisposition {
        guard let http = response as? HTTPURLResponse else { return .allow }
        if !(200...299).contains(http.statusCode) {
            part(of: task.taskIdentifier)?.failure = DownloadError.badStatus(http.statusCode)
            return .cancel
        }
        // A ranged request answered 200 sends the whole file; appending it would make an
        // oversized part, so it is refused before the transfer.
        if http.statusCode == 200,
           task.originalRequest?.value(forHTTPHeaderField: "Range") != nil {
            part(of: task.taskIdentifier)?.failure = DownloadError.rangesIgnored
            return .cancel
        }
        return .allow
    }

    fileprivate func completed(_ task: URLSessionTask, error: Error?) {
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

/// The session's delegate, forwarding to a weakly held owner. URLSession retains its
/// delegate until the session is invalidated, and the owner holds the session, so the
/// owner could never deinit as its own delegate.
private final class Relay: NSObject, URLSessionDataDelegate {
    // Written once, right after the owner's init, and only read afterwards.
    nonisolated(unsafe) weak var owner: RangeSession?

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        owner?.received(data, for: dataTask)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let owner else { return completionHandler(.cancel) }
        completionHandler(owner.disposition(of: response, for: dataTask))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        owner?.completed(task, error: error)
    }
}
