import Foundation

/// Brief runs of a tool for what it says about itself: an exit code, or version text.
enum ProcessProbe {
    /// How long a probe may run.
    static let defaultTimeout: TimeInterval = 20

    /// Runs a command for its exit code alone, discarding its output. Returns nil if the
    /// executable is missing or the command had to be killed at `timeout`.
    static func exitCode(_ executable: String, _ arguments: [String],
                         timeout: TimeInterval = defaultTimeout) -> Int32? {
        guard FileTools.isExecutable(executable) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = ChildProcess.discardedOutput
        process.standardError = ChildProcess.discardedOutput
        // Never the terminal: the point of the call is to learn whether the tool prompts.
        process.standardInput = ChildProcess.emptyInput
        do { try process.run() } catch { return nil }
        guard ChildProcess.waitForExit(process, within: timeout) else {
            ChildProcess.stop(process)
            return nil
        }
        return process.terminationStatus
    }

    /// Runs a command to capture its combined output, for version probes. Returns nil if the
    /// executable is missing or the output is not UTF-8.
    static func capture(_ executable: String, _ arguments: [String],
                        timeout: TimeInterval = defaultTimeout) -> String? {
        guard FileTools.isExecutable(executable) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // Never the terminal, as in `ProcessRunner`: a prompting probe would swallow keystrokes.
        process.standardInput = ChildProcess.emptyInput

        // Read as it arrives, so a talkative probe cannot fill the pipe.
        let output = Output()
        let reading = pipe.fileHandleForReading
        reading.readabilityHandler = { output.take(from: $0) }
        do { try process.run() } catch {
            reading.readabilityHandler = nil
            try? reading.close()
            return nil
        }

        // Waits for the process, not for the end of the pipe: the handler is not called at
        // end of file on every platform.
        if !ChildProcess.waitForExit(process, within: timeout) { ChildProcess.stop(process) }
        output.takeOver()
        reading.readabilityHandler = nil
        // The last write is still in the pipe. Read without waiting: a grandchild may
        // hold the writing end open.
        ChildProcess.readWhatIsWaiting(reading) { output.append($0) }
        try? reading.close()
        return output.text
    }

    /// The output so far, shared by the handler and the drain. A class: a local mutated
    /// from the handler's queue is a Sendable warning.
    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var draining = false

        /// Under the lock, so a chunk in flight lands before the drain reads the rest.
        func take(from handle: FileHandle) {
            lock.lock()
            defer { lock.unlock() }
            guard !draining else { return }
            let chunk = handle.availableData
            // Empty is end of file, where a handler left in place is called without end.
            if chunk.isEmpty { handle.readabilityHandler = nil } else { data.append(chunk) }
        }

        /// The rest of the pipe belongs to the drain.
        func takeOver() {
            lock.lock()
            draining = true
            lock.unlock()
        }

        func append(_ text: String) {
            lock.lock()
            data.append(Data(text.utf8))
            lock.unlock()
        }

        var text: String? {
            lock.lock()
            defer { lock.unlock() }
            return String(data: data, encoding: .utf8)
        }
    }
}
