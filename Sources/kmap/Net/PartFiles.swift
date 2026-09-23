import Foundation

/// The files a download keeps beside its destination while it runs: one `.partN` per
/// connection and a `.layout` recording how the ranges were cut.
struct PartFiles {
    let destination: URL

    /// The most parts one file is cut into, and so the most `.partN` files a run can
    /// leave behind.
    static let maxParts = 16

    /// Parts are joined in blocks of this size.
    static let joinBlock = 8 << 20

    func part(_ index: Int) -> URL { destination.appendingPathExtension("part\(index)") }

    var layout: URL { destination.appendingPathExtension("layout") }

    /// Whether any part is on disk, whatever count the last run used.
    var hasParts: Bool {
        (0..<Self.maxParts).contains { FileManager.default.fileExists(atPath: part($0).path) }
    }

    func removeParts() {
        for index in 0..<Self.maxParts { FileTools.removeIfPresent(part(index)) }
    }

    /// Parts are resumable only by a run with the same layout: under another part count
    /// the same `.partN` begins at a different byte, which a size check cannot tell. Parts
    /// of another layout are removed and this one is recorded.
    func keepLayout(size: Int64, count: Int) {
        let record = "\(size)/\(count)\n"
        if (try? String(contentsOf: layout, encoding: .utf8)) != record {
            removeParts()
            try? FileTools.write(record, to: layout)
        }
    }

    /// Joins `parts`, in order, into the destination, checks the size and removes them.
    ///
    /// - Throws: `DownloadError.io` if the result is not `expectedSize` bytes.
    func assemble(_ parts: [URL], expectedSize: Int64) throws {
        FileTools.removeIfPresent(destination)
        if parts.count == 1 {
            try FileTools.move(parts[0], to: destination)
            return
        }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw DownloadError.io("could not create \(destination.lastPathComponent)")
        }
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        for url in parts {
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            while let block = try input.read(upToCount: Self.joinBlock), !block.isEmpty {
                try out.write(contentsOf: block)
            }
        }
        try out.close()

        let finalSize = FileTools.size(of: destination)
        guard finalSize == expectedSize else {
            throw DownloadError.io("assembled \(Fmt.bytes(finalSize)), expected \(Fmt.bytes(expectedSize))")
        }
        for url in parts { FileTools.removeIfPresent(url) }
    }

    // MARK: Sweep

    /// Removes parts of downloads that will not be resumed: any whose destination has
    /// since arrived whole and current, and any older than `age`. A layout goes with the
    /// last of its parts.
    ///
    /// - Returns: The bytes reclaimed.
    @discardableResult
    static func sweepAbandoned(
        in directory: URL,
        olderThan age: TimeInterval = 14 * .day,
        now: Date = Date()
    ) -> Int64 {
        guard
            let walker = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        else { return 0 }
        var freed: Int64 = 0
        var touched: Set<URL> = []
        for case let url as URL in walker where isPart(url) {
            let files = PartFiles(destination: url.deletingPathExtension())
            var abandoned =
                FileManager.default.fileExists(atPath: files.destination.path)
                && CacheStamp.read(besides: files.destination) != nil
            if !abandoned {
                let modified =
                    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? now
                abandoned = now.timeIntervalSince(modified) > age
            }
            guard abandoned else { continue }
            freed += FileTools.size(of: url)
            FileTools.removeIfPresent(url)
            touched.insert(files.destination)
        }
        for destination in touched {
            let files = PartFiles(destination: destination)
            guard !files.hasParts else { continue }
            freed += FileTools.size(of: files.layout)
            FileTools.removeIfPresent(files.layout)
        }
        return freed
    }

    private static func isPart(_ url: URL) -> Bool {
        let ext = url.pathExtension
        return ext.hasPrefix("part") && Int(ext.dropFirst(4)) != nil
    }
}
