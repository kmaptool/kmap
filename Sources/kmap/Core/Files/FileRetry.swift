import Foundation

/// A file operation tried again while another process holds the file.
///
/// Windows lets any process open a file so that nobody else may replace, rename or delete
/// it, and the programs that watch the file system, antivirus, indexer, cloud clients,
/// hold a fresh file for a moment. The hold is brief, so the operation is tried again with
/// a growing pause, about a second in all; then the last error is thrown as it came. On
/// the Unixes an open file blocks none of these, so nothing there calls this.
enum FileRetry {
    /// The pauses between attempts. Short first, since a scanner is usually done in tens
    /// of milliseconds, and a little over a second in all.
    static let pausesMilliseconds: [UInt32] = [10, 20, 40, 80, 160, 320, 640]

    /// Runs `body`, and again after each pause while it fails with an error `isTransient`
    /// accepts. The error of the last attempt is thrown when the pauses run out.
    static func attempt<T>(
        isTransient: (Error) -> Bool,
        pause: (UInt32) -> Void = pause,
        _ body: () throws -> T
    ) throws -> T {
        var pauses = pausesMilliseconds[...]
        while true {
            do {
                return try body()
            } catch {
                guard isTransient(error), let next = pauses.popFirst() else { throw error }
                pause(next)
            }
        }
    }

    private static func pause(_ milliseconds: UInt32) {
        Thread.sleep(forTimeInterval: Double(milliseconds) / 1000)
    }
}
