import Foundation

/// Folders swept of what a killed run left, each at most once an hour in a run of kmap: a
/// sweep lists the whole folder, and a build asks for it per file.
enum SweptOnce {
    private static let swept = Locked<[String: Date]>([:])

    static func sweep(_ directory: URL, now: Date = Date(), _ body: (URL) -> Void) {
        let due = swept.withLock { last -> Bool in
            let path = directory.standardizedFileURL.path
            if let at = last[path], now.timeIntervalSince(at) < 3600 { return false }
            last[path] = now
            return true
        }
        if due { body(directory) }
    }
}
