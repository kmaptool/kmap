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
        var scan = Scan(prefer: prefer, exclude: Self.parse(exclude))
        for source in sources {
            try PBFReader(url: source).readInOrder(make: {
                Scan(prefer: prefer, exclude: MakeGPI.parse(exclude))
            }) { part in
                scan.take(part)
                part.clear()
            }
        }
        var points = try scan.resolve(urls: sources)
        if sources.count > 1 { points = Self.withoutRepeats(points) }
        guard !points.isEmpty else { throw Trouble.nothingToWrite }

        let page = Self.codePage(named: codepage)
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
            icon: showOnMap ? GPIFile.Icon.dot : nil
        )
        try FileTools.write(file, to: destination)

        var report = Report()
        report.written = points.count
        report.fromNodes = scan.points.count
        report.fromAreas = points.count - scan.points.count
        report.uninformative = scan.uninformative
        report.excluded = scan.excluded
        report.bytes = Int(FileTools.size(of: destination))
        return report
    }

    enum Trouble: Error, CustomStringConvertible, LocalizedError {
        case nothingToWrite

        var description: String {
            switch self {
            case .nothingToWrite: return "no described POIs found — nothing to write"
            }
        }
    }

    /// The code page a `--codepage` word stands for. Anything unnamed falls back to
    /// western European, which is what a map built without a choice uses.
    static func codePage(named name: String) -> Int {
        switch name {
        case "cp1250": return 1250
        case "cp1251": return 1251
        case "cp1253": return 1253
        case "cp1254": return 1254
        case "utf8", "utf-8": return CodePage.utf8
        default: return CodePage.westernEuropean
        }
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

    /// Whether a description says anything the name does not. Rejects one under 12
    /// characters, and one that repeats the name or is contained in it within 6 characters.
    static func worthCarrying(_ description: String, _ name: String) -> Bool {
        if description.count < 12 { return false }
        if name.isEmpty { return true }
        let a = description.lowercased(), b = name.lowercased()
        if a == b { return false }
        return !((a.contains(b) || b.contains(a)) && abs(a.count - b.count) < 6)
    }
}

extension MakeGPI {
    /// Geofabrik extracts overlap at their borders, so a joined map reads a border point
    /// once per region; the first copy stands.
    private static func withoutRepeats(_ points: [Point]) -> [Point] {
        struct Key: Hashable {
            let lat: UInt64, lon: UInt64
            let name: String, description: String
        }
        var seen = Set<Key>()
        return points.filter {
            seen.insert(Key(lat: $0.lat.bitPattern, lon: $0.lon.bitPattern, name: $0.name, description: $0.description))
                .inserted
        }
    }
}
