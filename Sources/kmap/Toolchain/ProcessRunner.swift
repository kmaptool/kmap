import Foundation

/// Runs an external command, streaming its output line by line, and can be cancelled.
final class ProcessRunner {

    /// Lines of the tail an error report shows.
    private static let reportedTail = 6
    /// A cancelled command's time to exit cleanly before SIGKILL.
    private static let cancelGrace: TimeInterval = 3

    struct Result {
        let exitCode: Int32
        let tail: [String]      // last lines, for error reporting
    }

    enum RunError: Error, LocalizedError {
        case launchFailed(String)
        case failed(command: String, exitCode: Int32, tail: [String])
        case cancelled

        var errorDescription: String? {
            switch self {
            case .launchFailed(let m): return t("could not launch: %@", m)
            case .cancelled: return t("cancelled")
            case .failed(let command, let code, let tail):
                let detail = tail.suffix(ProcessRunner.reportedTail).joined(separator: "\n  ")
                return t("%1$@ exited with code %2$d", command, code)
                    + (detail.isEmpty ? "" : "\n  \(detail)")
            }
        }
    }

    /// Records an exit that may arrive before anything waits for it. Installed before the
    /// process starts, so `signal` and `wait` may occur in either order; whichever comes
    /// second finds the first already recorded. Lock-guarded, callable from any thread.
    private final class ExitLatch {
        private let lock = NSLock()
        private var exited = false
        private var waiter: CheckedContinuation<Void, Never>?

        func signal() {
            lock.lock()
            exited = true
            let waiting = waiter
            waiter = nil
            lock.unlock()
            waiting?.resume()
        }

        func wait(_ continuation: CheckedContinuation<Void, Never>) {
            lock.lock()
            if exited {
                lock.unlock()
                continuation.resume()
                return
            }
            waiter = continuation
            lock.unlock()
        }
    }

    private let lock = NSLock()
    private var current: Process?
    private var currentLatch: ExitLatch?
    private var terminated = false

    // Synchronous accessors, so async callers never touch the lock directly.

    private func markCancelled() -> (Process, ExitLatch)? {
        lock.lock()
        terminated = true
        let process = current
        let latch = currentLatch
        lock.unlock()
        guard let process, let latch else { return nil }
        return (process, latch)
    }

    private func beginRun(_ process: Process, _ latch: ExitLatch) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if terminated { return false }
        current = process
        currentLatch = latch
        return true
    }

    private func endRun() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        current = nil
        currentLatch = nil
        return terminated
    }

    /// Terminates whatever is running and ends the wait for it, whether or not the signal
    /// was answered: a forked child holds the pipe open past the signalled process, so the
    /// termination handler may never fire. Safe to call from another task.
    func cancel() {
        guard let (process, latch) = markCancelled() else { return }
        if process.isRunning { process.terminate() }
        // `cancelGrace` to exit cleanly, then SIGKILL. Reaches only the signalled process,
        // so the caller does not wait on it.
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.cancelGrace) {
            ChildProcess.insist(on: process)
        }
        latch.signal()
    }

    /// Runs `executable` with `arguments`, calling `onLine` for every line of stdout/stderr.
    /// Throws `RunError.failed` on a non-zero exit unless `allowFailure` is set.
    @discardableResult
    func run(_ executable: String,
             _ arguments: [String],
             cwd: URL? = nil,
             environment: [String: String]? = nil,
             allowFailure: Bool = false,
             onLine: @escaping (String) -> Void) async throws -> Result {

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        if let environment {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in environment { env[k] = v }
            process.environment = env
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // Otherwise the child inherits kmap's own stdin, the terminal in raw mode. An empty
        // input turns any prompt into an immediate EOF and a reported failure.
        process.standardInput = ChildProcess.emptyInput

        // Before `run()`, not after: see `ExitLatch`.
        let latch = ExitLatch()
        process.terminationHandler = { _ in latch.signal() }

        guard beginRun(process, latch) else { throw RunError.cancelled }

        let collector = LineCollector(onLine: onLine)
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { fh in
            let data = fh.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            collector.ingest(chunk)
        }

        do {
            try process.run()
        } catch {
            handle.readabilityHandler = nil
            // Closing the read end here keeps a failed launch from leaking a descriptor.
            try? handle.close()
            _ = endRun()
            throw RunError.launchFailed(error.localizedDescription)
        }

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                latch.wait(continuation)
            }
        } onCancel: {
            self.cancel()
        }

        // Drains what is in the pipe rather than calling `readToEnd()`, which waits for the
        // pipe to close: a forked grandchild can hold the writing end open indefinitely.
        handle.readabilityHandler = nil
        let wasCancelled = endRun()
        // A cancelled command is not read at all: its tail is not reported, and the pipe may
        // still be held open by something that outlived the signal.
        if !wasCancelled {
            drainWithoutWaiting(handle, into: collector)
            collector.finish()
        }
        try? handle.close()

        // Thrown before `terminationStatus` is read: a cancelled command may still be alive,
        // and reading the exit status of a live process traps.
        if wasCancelled { throw RunError.cancelled }

        let finalTail = collector.snapshot
        let code = process.terminationStatus
        if code != 0 && !allowFailure {
            throw RunError.failed(command: (executable as NSString).lastPathComponent,
                                  exitCode: code, tail: finalTail)
        }
        return Result(exitCode: code, tail: finalTail)
    }

    /// Reads whatever is already in the pipe and returns without waiting for more. The
    /// platform-specific part is in `ChildProcess`.
    private func drainWithoutWaiting(_ handle: FileHandle, into collector: LineCollector) {
        ChildProcess.readWhatIsWaiting(handle) { collector.ingest($0) }
    }
}
