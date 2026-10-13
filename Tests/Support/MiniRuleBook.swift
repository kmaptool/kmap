import Foundation

@testable import kmap

/// A few default rules on disk, enough to read meanings against: a path, a footway written
/// in 2 files, and a fill.
enum MiniRuleBook {
    static func load() throws -> DefaultRuleBook {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("rules-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileTools.write(
            "highway=path [0x16 resolution 22]\nhighway=footway [0x16 resolution 23]\n",
            to: folder.appendingPathComponent("lines")
        )
        try FileTools.write(
            "highway=footway [0x16 resolution 23]\nlanduse=forest [0x50 resolution 19]\n",
            to: folder.appendingPathComponent("polygons")
        )
        try FileTools.write("amenity=fuel [0x2f01 resolution 24]\n", to: folder.appendingPathComponent("points"))
        return DefaultRuleBook.load(from: folder)
    }

    /// A meaning seen on `count` elements, starting at id `first`.
    static func bucket(
        _ lines: [DefaultRuleBook.Line],
        tag: String,
        count: Int,
        first: Int64 = 1,
        built: Int = 0
    ) -> StyleRecovery.MeaningBucket {
        var out = StyleRecovery.MeaningBucket(lines: lines)
        out.tags[tag] = count
        out.ids = Set(first..<(first + Int64(count)))
        out.built = built
        return out
    }

    static func reading(
        _ kind: ElementDumper.Kind,
        _ type: Int,
        foreign: Bool,
        _ buckets: [String: StyleRecovery.MeaningBucket]
    ) -> StyleRecovery.CodeReading {
        StyleRecovery.CodeReading(
            key: Evidence.key(kind, type),
            code: Evidence.ForCode(kind: kind, type: type),
            buckets: buckets,
            meant: buckets.values.reduce(0) { $0 + $1.count },
            foreign: foreign
        )
    }
}
