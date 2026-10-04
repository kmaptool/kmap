import Foundation

/// How long a source's list of its tiles is trusted.
enum DEMTileList {
    /// A list older than this is asked for again.
    static let maxAge: TimeInterval = 30 * 86400
    /// After a refresh that failed, the old list serves this long before the next try.
    static let retryAfter: TimeInterval = 86400

    /// Whether a list written at `modified` is due again; undated or future-dated is.
    static func isStale(modified: Date?, now: Date) -> Bool {
        guard let modified else { return true }
        let age = now.timeIntervalSince(modified)
        return age < 0 || age > maxAge
    }

    /// Dates the list so that it is stale again `retryAfter` from `now`.
    static func postpone(_ file: URL, from now: Date) {
        let date = now.addingTimeInterval(retryAfter - maxAge)
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
    }
}
