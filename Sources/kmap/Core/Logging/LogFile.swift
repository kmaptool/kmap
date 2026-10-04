import Foundation

/// Mirrors events to a file as they arrive, so a finished run leaves a readable record.
///
/// `KMAP_LOG_TIME` puts seconds since the file was opened in front of every line.
final class LogFile: LogSink {
    private let lock = NSLock()
    private var handle: FileHandle?
    private let born = Date()
    private static let stamped = ProcessInfo.processInfo.environment["KMAP_LOG_TIME"] != nil

    init?(at url: URL) {
        Paths.ensure(url.deletingLastPathComponent())
        guard let handle = try? FileTools.openForWriting(url, appending: false) else { return nil }
        self.handle = handle
    }

    deinit { try? handle?.close() }

    func receive(_ event: LogEvent) {
        let stamp =
            Self.stamped
            ? String(format: "%8.2f ", event.at.timeIntervalSince(born)) : ""
        guard let data = (stamp + event.text + "\n").data(using: .utf8) else { return }
        lock.lock()
        try? handle?.write(contentsOf: data)
        lock.unlock()
    }
}
