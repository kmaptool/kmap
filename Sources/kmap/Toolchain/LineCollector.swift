import Foundation

/// Hands a command's output on line by line and keeps the last lines for an error report.
/// State is behind a lock: `readabilityHandler` runs on whatever thread has the data.
final class LineCollector {
    /// Lines kept for the report.
    static let tailLength = 40

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
        let over = tail.count - LineCollector.tailLength
        if over > 0 { tail.removeFirst(over) }
    }

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return tail
    }
}
