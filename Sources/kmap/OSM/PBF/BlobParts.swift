import Foundation

/// What each data blob of a file holds, learned the first time a pass decodes every blob
/// and kept for the rest of the run. A later pass skips, without inflating it, any blob
/// holding nothing it asks for: the passes over an extract each want a part of it, and
/// inflating the rest was most of their reading.
enum BlobParts {
    /// A file as last read whole: every data blob's length, and what each held.
    private struct Known {
        let lengths: [Int]
        let parts: [OSMParts]
    }

    private static let known = Locked<[String: Known]>([:])

    /// The file as it is now: a file rewritten in between is another file. Asked of the
    /// file system each time; a URL's own resource values are cached on the URL.
    private static func key(_ url: URL) -> String? {
        let path = url.standardizedFileURL.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let size = (attributes[.size] as? NSNumber)?.int64Value,
            let date = attributes[.modificationDate] as? Date
        else { return nil }
        return "\(path)|\(size)|\(date.timeIntervalSinceReferenceDate)"
    }

    /// Which of `blobs` a pass asking for `wanted` has to read, or nil for all of them:
    /// nothing known about the file, a pass that wants every part, or blobs laid out
    /// otherwise than when the file was learned, which a time stamp too coarse to see a
    /// rewrite would otherwise hide.
    static func needed(_ url: URL, blobs: [UnsafeRawBufferPointer], wanted: OSMParts) -> [Int]? {
        guard wanted != .all, let key = key(url), let file = known.withLock({ $0[key] }),
            file.lengths.count == blobs.count,
            zip(file.lengths, blobs).allSatisfy({ $0 == $1.count })
        else { return nil }
        return file.parts.indices.filter { !file.parts[$0].isDisjoint(with: wanted) }
    }

    /// Keeps what a pass that read every blob found in each.
    static func learn(_ url: URL, lengths: [Int], parts: [OSMParts]) {
        guard let key = key(url) else { return }
        known.withLock { $0[key] = Known(lengths: lengths, parts: parts) }
    }

    /// The blobs a pass asking for `wanted` has to read, and, when that is every blob, a
    /// log to note what each holds in.
    static func select(
        _ blobs: [UnsafeRawBufferPointer],
        of url: URL,
        wanted: OSMParts
    ) -> (blobs: [UnsafeRawBufferPointer], log: Log?) {
        guard let needed = needed(url, blobs: blobs, wanted: wanted) else {
            return (blobs, Log(url: url, lengths: blobs.map(\.count)))
        }
        return (needed.map { blobs[$0] }, nil)
    }

    /// What each blob of a file holds, noted by the workers as they decode it. Each slot is
    /// written by the 1 worker decoding that blob, so it needs no lock.
    final class Log: @unchecked Sendable {
        private let url: URL
        private let lengths: [Int]
        private let parts: UnsafeMutablePointer<OSMParts>

        init(url: URL, lengths: [Int]) {
            self.url = url
            self.lengths = lengths
            parts = .allocate(capacity: lengths.count)
            parts.initialize(repeating: [], count: lengths.count)
        }

        deinit {
            parts.deinitialize(count: lengths.count).deallocate()
        }

        func note(_ blob: Int, holds held: OSMParts) {
            parts[blob] = held
        }

        /// Keeps the log for the passes after this one; only once every blob is noted.
        func keep() {
            BlobParts.learn(
                url,
                lengths: lengths,
                parts: Array(UnsafeBufferPointer(start: parts, count: lengths.count))
            )
        }
    }
}
