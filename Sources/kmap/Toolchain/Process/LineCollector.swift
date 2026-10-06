import Foundation

/// Hands a command's output on line by line and keeps the last lines for an error report.
/// State is behind a lock: `readabilityHandler` runs on whatever thread has the data.
/// Fed from a pipe's readability handler and finished from the caller's thread.
/// `@unchecked Sendable` stands on `lock`: the pending text, the tail and the finishing
/// flag are reached only under it.
final class LineCollector: @unchecked Sendable {
    /// Lines kept for the report.
    static let tailLength = 40

    private let lock = NSLock()
    /// Bytes, not text: a pipe hands over whatever fits, and a cut inside a multibyte
    /// character must not lose the chunk. Lines are decoded once complete.
    private var pending: [UInt8] = []
    private var tail: [String] = []
    private let onLine: (String) -> Void
    /// Set by `finish()`. Removing the readability handler does not wait for a call
    /// already running, so a chunk taken after the last flush flushes itself.
    private var finishing = false

    init(onLine: @escaping (String) -> Void) {
        self.onLine = onLine
    }

    func ingest(_ chunk: String) { ingest(bytes: Array(chunk.utf8)) }

    /// Takes a chunk as it arrives and calls `onLine` for every complete line in it.
    func ingest<Bytes: Collection>(bytes chunk: Bytes) where Bytes.Element == UInt8 {
        var complete: [String] = []
        lock.lock()
        pending.append(contentsOf: chunk)
        var lineStart = 0
        var at = 0
        while at < pending.count {
            guard pending[at] == 0x0A else { at += 1; continue }
            let line = String(decoding: pending[lineStart..<at], as: UTF8.self)
            at += 1
            lineStart = at
            let cleaned = stripControlSequences(line)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            guard !cleaned.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            remember(cleaned)
            complete.append(cleaned)
        }
        if lineStart > 0 { pending.removeFirst(lineStart) }
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
        let rest = String(decoding: pending, as: UTF8.self)
        pending = []
        lock.unlock()
        guard !rest.isEmpty else { return }
        // `TextLines.of` splits on scalars and handles all 3 kinds of line ending.
        for line in TextLines.of(rest) where !line.isEmpty {
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
