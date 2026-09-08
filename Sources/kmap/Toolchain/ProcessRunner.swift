import Foundation

/// Runs an external command, streaming its output line by line, and can be cancelled.
final class ProcessRunner {

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
                let detail = tail.suffix(6).joined(separator: "\n  ")
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
                tail.append(cleaned)
                if tail.count > 40 { tail.removeFirst(tail.count - 40) }
                complete.append(cleaned)
            }
            lock.unlock()
            for line in complete { onLine(line) }
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
                lock.lock(); tail.append(cleaned); lock.unlock()
                onLine(cleaned)
            }
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
        // Three seconds to exit cleanly, then SIGKILL. Reaches only the signalled process,
        // so the caller does not wait on it.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
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
            collector.flush()
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
                         timeout: TimeInterval = 20) -> Int32? {
        guard FileTools.isExecutable(executable) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = ChildProcess.discardedOutput
        process.standardError = ChildProcess.discardedOutput
        // Never the terminal: the point of the call is to learn whether the tool prompts.
        process.standardInput = ChildProcess.emptyInput
        do { try process.run() } catch { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            ChildProcess.insist(on: process)
            process.waitUntilExit()
            return nil
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Runs a command to capture its combined output, for version probes. Returns nil if the
    /// executable is missing or the output is not UTF-8.
    static func capture(_ executable: String, _ arguments: [String], timeout: TimeInterval = 20) -> String? {
        guard FileTools.isExecutable(executable) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // Never the terminal, as in `run`: a prompting probe would swallow keystrokes.
        process.standardInput = ChildProcess.emptyInput
        do { try process.run() } catch { return nil }

        // Read on the pipe's own queue with a semaphore for the end, so `timeout` is real:
        // `availableData` blocks, so a read loop with a clock check would not honour it.
        let lock = NSLock()

        nonisolated(unsafe) var data = Data()
        let finished = DispatchSemaphore(value: 0)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {                 // end of the pipe
                handle.readabilityHandler = nil
                finished.signal()
                return
            }
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        let gaveUp = finished.wait(timeout: .now() + timeout) == .timedOut
        if gaveUp {
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                ChildProcess.insist(on: process)
                _ = finished.wait(timeout: .now() + 2)
            }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        try? pipe.fileHandleForReading.close()
        // Only a probe that finished on its own is waited for: after a kill, `waitUntilExit`
        // can block for as long as an unsignalled grandchild lives.
        if !gaveUp { process.waitUntilExit() }
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8)
    }
}
