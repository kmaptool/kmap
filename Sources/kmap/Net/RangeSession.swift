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
        let end: Int64             // inclusive
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

    /// Fetches what is left of `part` in one request, appending to its file. Without
    /// ranges the server sends the file from the top, so the part starts over.
    func fetch(_ part: Part, from url: URL, ranged: Bool) async throws {
        // A retry sleep can end after `cancel()` invalidated the session, and a task made
        // on a dead session never completes.
        if isCancelled { throw DownloadError.cancelled }
        var request = URLRequest(url: url)
        if ranged {
            request.setValue("bytes=\(part.start + part.written)-\(part.end)",
                             forHTTPHeaderField: "Range")
        } else {
            FileTools.removeIfPresent(part.url)
        }

        Paths.ensure(part.url.deletingLastPathComponent())
        if !FileManager.default.fileExists(atPath: part.url.path) {
            _ = FileManager.default.createFile(atPath: part.url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: part.url)
        try handle.seekToEnd()

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

/// The session's delegate: writes each task's bytes to its part and wakes whoever awaits
/// it. It holds no reference back to the session that owns it, so the two make no cycle.
private final class Receiver: NSObject, URLSessionDataDelegate, Sendable {

    /// One request in flight.
    private struct Transfer {
        let part: Int
        let handle: FileHandle
        let continuation: CheckedContinuation<Void, Error>
        /// Why the task was cancelled from in here, which its own error does not say.
        var failure: Error?
    }

    private struct State {
        var transfers: [Int: Transfer] = [:]  // by URLSessionTask.taskIdentifier
        var cancelled = false
    }

    private let state = Locked(State())
    private let progress: DownloadProgress

    init(progress: DownloadProgress) {
        self.progress = progress
    }

    func markCancelled() { state.withLock { $0.cancelled = true } }

    var isCancelled: Bool { state.withLock { $0.cancelled } }

    func expect(_ task: URLSessionTask, part: Int, into handle: FileHandle,
                resuming continuation: CheckedContinuation<Void, Error>) {
        state.withLock {
            $0.transfers[task.taskIdentifier] = Transfer(part: part, handle: handle,
                                                         continuation: continuation)
        }
    }

    /// Records why a task is being cancelled, for its completion to report.
    private func fail(_ task: URLSessionTask, with error: Error) {
        state.withLock { $0.transfers[task.taskIdentifier]?.failure = error }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // The write happens outside the lock: the delegate queue is serial, so one task's
        // bytes arrive in order and nothing else touches its handle.
        guard let transfer = state.withLock({ $0.transfers[dataTask.taskIdentifier] }) else { return }
        do {
            try transfer.handle.write(contentsOf: data)
            progress.advance(part: transfer.part, by: Int64(data.count))
        } catch {
            fail(dataTask, with: DownloadError.io(error.localizedDescription))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { return completionHandler(.allow) }
        if !(200...299).contains(http.statusCode) {
            fail(dataTask, with: DownloadError.badStatus(http.statusCode))
            return completionHandler(.cancel)
        }
        // A ranged request answered 200 sends the whole file; appending it would make an
        // oversized part, so it is refused before the transfer.
        if http.statusCode == 200,
           dataTask.originalRequest?.value(forHTTPHeaderField: "Range") != nil {
            fail(dataTask, with: DownloadError.rangesIgnored)
            return completionHandler(.cancel)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        let (transfer, wasCancelled) = state.withLock {
            ($0.transfers.removeValue(forKey: task.taskIdentifier), $0.cancelled)
        }
        guard let transfer else { return }
        // Closed before the caller wakes: it reads the part's length to know how far it got.
        try? transfer.handle.close()

        if let failure = transfer.failure {
            transfer.continuation.resume(throwing: failure)
        } else if let error {
            transfer.continuation.resume(throwing: wasCancelled ? DownloadError.cancelled : error)
        } else {
            transfer.continuation.resume()
        }
    }
}
