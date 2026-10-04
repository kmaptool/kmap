import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension RangeSession {
    /// The session's delegate: writes each task's bytes to its part and wakes whoever awaits
    /// it. It holds no reference back to the session that owns it, so the two make no cycle.
    final class Receiver: NSObject, URLSessionDataDelegate, Sendable {
        /// One request in flight.
        struct Transfer {
            let part: Int
            let handle: FileHandle
            let continuation: CheckedContinuation<Void, Error>
            /// Why the task was cancelled from in here, which its own error does not say.
            var failure: Error?
        }

        struct State {
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

        func expect(
            _ task: URLSessionTask,
            part: Int,
            into handle: FileHandle,
            resuming continuation: CheckedContinuation<Void, Error>
        ) {
            state.withLock {
                $0.transfers[task.taskIdentifier] = Transfer(
                    part: part,
                    handle: handle,
                    continuation: continuation
                )
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

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let http = response as? HTTPURLResponse else { return completionHandler(.allow) }
            if !(200...299).contains(http.statusCode) {
                fail(dataTask, with: DownloadError.badStatus(http.statusCode))
                return completionHandler(.cancel)
            }
            // A ranged request answered 200 sends the whole file; appending it would make an
            // oversized part, so it is refused before the transfer.
            if http.statusCode == 200,
                dataTask.originalRequest?.value(forHTTPHeaderField: "Range") != nil
            {
                fail(dataTask, with: DownloadError.rangesIgnored)
                return completionHandler(.cancel)
            }
            // A 206 for bytes other than those asked would be appended at the wrong place.
            if http.statusCode == 206,
                let asked = dataTask.originalRequest?.value(forHTTPHeaderField: "Range"),
                let served = http.value(forHTTPHeaderField: "Content-Range"),
                !RangeSession.serves(served, asked: asked)
            {
                fail(dataTask, with: DownloadError.rangesIgnored)
                return completionHandler(.cancel)
            }
            completionHandler(.allow)
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
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
}
