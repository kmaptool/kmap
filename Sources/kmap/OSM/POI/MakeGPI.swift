import Foundation

/// Builds a Garmin Custom POI (.gpi) of the objects that carry a description.
///
/// A Garmin `.img` POI record has no description field; a `.gpi` carries a multi-line one.
/// Reads the extract, decides what is worth carrying, and hands the result to ``GPIFile``,
/// which writes the Garmin format itself.
struct MakeGPI {
    /// The extracts to read: one region, or every region of a joined map. A point that
    /// two overlapping extracts both carry is written once.
    var sources: [URL]
    var destination: URL

    init(source: URL, destination: URL) {
        self.sources = [source]
        self.destination = destination
    }

    init(sources: [URL], destination: URL) {
        self.sources = sources
        self.destination = destination
    }
    var codepage = "cp1251"
    var category = "kmap"
    var prefer = "ru"
    var showOnMap = false
    /// `key=value` or `key=*`, mirroring the app's Hide on map choice.
    var exclude: [String] = []
    /// Asked as the extracts are read, which can take minutes: true stops with a
    /// `CancellationError`, nothing written.
    var shouldStop: () -> Bool = { false }

    struct Report {
        var written = 0
        var fromNodes = 0
        var fromAreas = 0
        var uninformative = 0
        var excluded = 0
        var bytes = 0
    }

    struct Point {
        var lat: Double
        var lon: Double
        var name: String
        var description: String
    }

    func run() throws -> Report {
        // Before the extract is read, which can take minutes.
        guard let page = Self.codePage(named: codepage) else { throw Trouble.unknownCodePage(codepage) }
        var scan = Scan(prefer: prefer, exclude: Self.parse(exclude))
        // Per file, the way ids of each data blob in order: the pass reads every blob.
        var blobWays: [[ClosedRange<Int64>?]] = []
        for source in sources {
            var ranges: [ClosedRange<Int64>?] = []
            try PBFReader(url: source).readInOrder(make: {
                Scan(prefer: prefer, exclude: MakeGPI.parse(exclude))
            }) { part in
                if shouldStop() { throw CancellationError() }
                ranges.append(part.wayIDs)
                scan.take(part)
                part.clear()
            }
            blobWays.append(ranges)
        }
        if shouldStop() { throw CancellationError() }
        try scan.addMultipolygons(urls: sources, blobWays: blobWays)
        var points = try scan.resolve(urls: sources)
        // The nodes come first, then the areas: counted after the repeats are gone.
        // Overlapping extracts carry a border point twice: it is written once.
        let kept = Self.keptOnce(points)
        let fromNodes = kept.prefix(scan.points.count).filter { $0 }.count
        points = zip(points, kept).filter(\.1).map(\.0)
        guard !points.isEmpty else { throw Trouble.nothingToWrite }

        // Lossy on purpose: a letter the code page has no room for becomes "?" rather
        // than costing the whole point.
        func encoded(_ text: String) -> [UInt8] {
            CodePage.encode(text, codePage: page, lossy: true) ?? []
        }
        let file = GPIFile.data(
            points: points.map {
                GPIFile.Point(
                    lat: $0.lat,
                    lon: $0.lon,
                    name: encoded($0.name),
                    description: encoded($0.description)
                )
            },
            category: encoded(category),
            codePage: page,
            fileName: destination.lastPathComponent,
            icon: showOnMap ? GPIFile.Icon.dot : nil,
            madeAt: Self.dataDate(of: sources)
        )
        try FileTools.write(file, to: destination)

        var report = Report()
        report.written = points.count
        report.fromNodes = fromNodes
        report.fromAreas = points.count - fromNodes
        report.uninformative = scan.uninformative
        report.excluded = scan.excluded
        report.bytes = Int(FileTools.size(of: destination))
        return report
    }

    enum Trouble: Error, CustomStringConvertible, LocalizedError {
        case nothingToWrite
        case unknownCodePage(String)

        var description: String {
            switch self {
            case .nothingToWrite: return "no described POIs found — nothing to write"
            case .unknownCodePage(let name):
                return "no code page \(name) — cp1250 to cp1254, or utf8"
            }
        }
    }

    /// When the file's data is from, so the same extracts give the same bytes: the
    /// newest extract's date, or `SOURCE_DATE_EPOCH` where a reproducible build sets it.
    static func dataDate(
        of sources: [URL],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Date {
        if let epoch = environment["SOURCE_DATE_EPOCH"].flatMap(TimeInterval.init) {
            return Date(timeIntervalSince1970: epoch)
        }
        return sources.compactMap { FileTools.modified(of: $0) }.max() ?? Date()
    }

    /// The code page a `--codepage` word stands for: `cp1251`, `CP1251` or `1251`, or
    /// `utf8`. Nil for one there is no table for, which would turn every letter into `?`.
    static func codePage(named name: String) -> Int? {
        let word = name.trimmingCharacters(in: .whitespaces).lowercased()
        if word == "utf8" || word == "utf-8" { return CodePage.utf8 }
        guard let number = Int(word.hasPrefix("cp") ? String(word.dropFirst(2)) : word) else { return nil }
        let known = Set(CodePage.supported + [CodePage.westernEuropean, CodePage.utf8])
        return known.contains(number) ? number : nil
    }

    static func parse(_ values: [String]) -> (exact: Set<String>, wildcard: Set<String>) {
        var exact = Set<String>(), wildcard = Set<String>()
        for item in values {
            for part in item.split(separator: ",") {
                let text = part.trimmingCharacters(in: .whitespaces)
                guard let split = text.firstIndex(of: "=") else { continue }
                let key = String(text[text.startIndex..<split])
                let value = String(text[text.index(after: split)...])
                if value == "*" { wildcard.insert(key) } else { exact.insert(text) }
            }
        }
        return (exact, wildcard)
    }

    /// Whether a description says anything the name does not. Rejects a single word under
    /// 12 characters, a bare "spring", but not a short phrase of several words; and one
    /// that repeats the name or is contained in it within 6 characters.
    static func worthCarrying(_ description: String, _ name: String) -> Bool {
        let words = description.split(whereSeparator: { $0.isWhitespace }).count
        if description.count < 12 && words < 2 { return false }
        if name.isEmpty { return true }
        let a = description.lowercased(), b = name.lowercased()
        if a == b { return false }
        return !((a.contains(b) || b.contains(a)) && abs(a.count - b.count) < 6)
    }
}

extension MakeGPI {
    /// Geofabrik extracts overlap at their borders, so a joined map reads a border point
    /// once per region; the first copy stands.
    /// Whether each point is the first of its kind, place, name and description alike.
    static func keptOnce(_ points: [Point]) -> [Bool] {
        struct Key: Hashable {
            let lat: UInt64, lon: UInt64
            let name: String, description: String
        }
        var seen = Set<Key>()
        return points.map {
            seen.insert(Key(lat: $0.lat.bitPattern, lon: $0.lon.bitPattern, name: $0.name, description: $0.description))
                .inserted
        }
    }
}
