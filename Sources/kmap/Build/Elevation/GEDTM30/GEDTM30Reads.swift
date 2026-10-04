import Foundation

// MARK: Reading the file by range

extension GEDTM30 {
    /// Bytes `offset..<offset + count` of the file.
    typealias Read = @Sendable (_ offset: Int64, _ count: Int) async throws -> Data

    /// HTTP reads via a part file, so a 200 for the whole file is refused before its body.
    /// Reads are kept for the run: estimates and builds ask for the same header and index.
    func remote() -> Read {
        let url = url
        return { offset, count in
            let key = ReadKey(url: url, offset: offset, count: count)
            if let known = Self.readsKept.withLock({ $0.data[key] }) { return known }
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("kmap-gedtm-\(UUID().uuidString)")
            // A failed or stopped read leaves its part file.
            defer {
                FileTools.removeIfPresent(file)
                FileTools.removeIfPresent(PartFiles(destination: file).part(0))
            }
            try await Downloader(log: Log()).download(url: url, from: offset, count: Int64(count), to: file)
            let data = try Data(contentsOf: file)
            Self.readsKept.withLock { $0.keep(data, for: key) }
            return data
        }
    }

    private struct ReadKey: Hashable {
        let url: URL
        let offset: Int64
        let count: Int
    }

    /// Up to `mostKept` bytes; past that nothing more is kept.
    private struct ReadsKept {
        var data: [ReadKey: Data] = [:]
        var bytes = 0

        mutating func keep(_ read: Data, for key: ReadKey) {
            guard data[key] == nil, bytes + read.count <= GEDTM30.mostKept else { return }
            data[key] = read
            bytes += read.count
        }
    }

    private static let mostKept = 32 << 20
    private static let readsKept = Locked(ReadsKept())

    /// Forgets the kept reads if parsing fails, so a bad read is not served again.
    static func parsing<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            // Any failure: a bad header can also send the next read past the end of the file.
            readsKept.withLock { $0 = ReadsKept() }
            throw error
        }
    }

    /// For the tests.
    static var keptReads: Int { readsKept.withLock { $0.data.count } }
}
