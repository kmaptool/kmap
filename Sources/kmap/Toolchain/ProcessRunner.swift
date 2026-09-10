import Foundation

/// Runs an external command, streaming its output line by line, and can be cancelled.
final class ProcessRunner {

    /// Lines of output kept for an error report, and how many of them it shows.
    private static let tailLength = 40
    private static let reportedTail = 6
    /// How long a probe may run, and how long a process is given to die once told to.
    private static let probeTimeout: TimeInterval = 20
    private static let exitGrace: TimeInterval = 2
    /// A cancelled command's time to exit cleanly before SIGKILL.
    private static let cancelGrace: TimeInterval = 3
    /// Between two looks at `isRunning`.
    private static let pollInterval: TimeInterval = 0.02

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

    /// Accumulates output arriving on the pipe's background queue. All state is behind a
    /// lock because `readabilityHandler` is called off whatever thread has the data.
    private final class LineCollector {
        private let lock = NSLock()
        private var pending = ""
        private var tail: [String] = []
        private let onLine: (String) -> Void
        /// Set by `finish()`. Removing the readability handler does not wait for a call
        /// already running, so a chunk taken after the last flush flushes itself.
        private var finishing = false

        init(onLine: @escaping (String) -> Void) {
            self.onLine = onLine
        }

        /// Takes a chunk as it arrives and calls `onLine` for every complete line in it.
        /// Splits on unicode scalars, not Characters: Swift counts `\r\n` as one grapheme
        /// cluster, so a Character search never finds the end of a CRLF line.
        func ingest(_ chunk: String) {
            var complete: [String] = []
            lock.lock()
            pending += chunk
            while let newline = pending.unicodeScalars.firstIndex(of: "\n") {
                let scalars = pending.unicodeScalars
                let line = String(scalars[scalars.startIndex..<newline])
                pending = String(scalars[scalars.index(after: newline)...])
                let cleaned = stripControlSequences(line)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                guard !cleaned.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                remember(cleaned)
                complete.append(cleaned)
            }
            let late = finishing
            lock.unlock()
            for line in complete { onLine(line) }
            if late { flush() }
        }

        /// No more chunks are expected; a late one flushes itself.
        func finish() {
            lock.lock()
            finishing = true
            lock.unlock()
            flush()
        }

        /// Emits whatever is left without a trailing newline.
        func flush() {
            lock.lock()
            let rest = pending
            pending = ""
            lock.unlock()
            guard !rest.isEmpty else { return }
            // `Lines.of` splits on scalars and handles all three kinds of line ending.
            for line in Lines.of(rest) where !line.isEmpty {
                let cleaned = stripControlSequences(line)
                guard !cleaned.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                lock.lock(); remember(cleaned); lock.unlock()
                onLine(cleaned)
            }
        }

        /// Keeps the last `tailLength` lines. Called with the lock held.
        private func remember(_ line: String) {
            tail.append(line)
            let over = tail.count - ProcessRunner.tailLength
            if over > 0 { tail.removeFirst(over) }
        }

        var snapshot: [String] {
            lock.lock()
            defer { lock.unlock() }
            return tail
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

    /// Runs a command for its exit code alone, discarding its output. Returns nil if the
    /// executable is missing or the command had to be killed at `timeout`.
    static func exitCode(_ executable: String, _ arguments: [String],
                         timeout: TimeInterval = probeTimeout) -> Int32? {
        guard FileTools.isExecutable(executable) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = ChildProcess.discardedOutput
        process.standardError = ChildProcess.discardedOutput
        // Never the terminal: the point of the call is to learn whether the tool prompts.
        process.standardInput = ChildProcess.emptyInput
        do { try process.run() } catch { return nil }
        guard waitForExit(process, within: timeout) else {
            stop(process)
            return nil
        }
        return process.terminationStatus
    }

    /// Polls for the exit instead of `waitUntilExit()`, which deadlocks on the main thread
    /// on Linux: Foundation there delivers the exit through the main queue, and the
    /// interface and `doctor` probe from the main thread. True once the process has exited.
    @discardableResult
    static func waitForExit(_ process: Process, within: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(within)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return !process.isRunning
    }

    /// Asks the process to stop and gives it `exitGrace`; then insists, and waits again.
    private static func stop(_ process: Process) {
        process.terminate()
        if !waitForExit(process, within: exitGrace) {
            ChildProcess.insist(on: process)
            waitForExit(process, within: exitGrace)
        }
    }

    /// Runs a command to capture its combined output, for version probes. Returns nil if the
    /// executable is missing or the output is not UTF-8.
    static func capture(_ executable: String, _ arguments: [String],
                        timeout: TimeInterval = probeTimeout) -> String? {
        guard FileTools.isExecutable(executable) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // Never the terminal, as in `run`: a prompting probe would swallow keystrokes.
        process.standardInput = ChildProcess.emptyInput

        // Read as it arrives, so a talkative probe cannot fill the pipe and block on it.
        // The read is under the lock: once `draining` is set nothing more is taken here,
        // and a chunk in flight has landed before the drain below reads the rest.
        let lock = NSLock()
        nonisolated(unsafe) var data = Data()
        nonisolated(unsafe) var draining = false
        let reading = pipe.fileHandleForReading
        reading.readabilityHandler = { handle in
            lock.lock()
            defer { lock.unlock() }
            guard !draining else { return }
            let chunk = handle.availableData
            // Empty is end of file, where a handler left in place is called without end.
            if chunk.isEmpty { handle.readabilityHandler = nil } else { data.append(chunk) }
        }
        do { try process.run() } catch {
            reading.readabilityHandler = nil
            try? reading.close()
            return nil
        }

        // The wait is for the process, not for the end of the pipe: the handler is not
        // called at end of file on every platform.
        if !waitForExit(process, within: timeout) { stop(process) }
        lock.lock()
        draining = true
        lock.unlock()
        reading.readabilityHandler = nil
        // What the child wrote last is still in the pipe, read without waiting: a
        // grandchild may hold the writing end open.
        ChildProcess.readWhatIsWaiting(reading) { data.append(Data($0.utf8)) }
        try? reading.close()
        return String(data: data, encoding: .utf8)
    }
}
