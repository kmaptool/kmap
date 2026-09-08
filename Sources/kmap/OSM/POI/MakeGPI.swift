import Foundation

/// Builds a Garmin Custom POI (.gpi) of the objects that carry a description.
///
/// A Garmin `.img` POI record has no description field; a `.gpi` carries a multi-line one.
/// Reads the extract, decides what is worth carrying, and hands the result to ``GPIFile``,
/// which writes the Garmin format itself.
struct MakeGPI {
    private static let descriptionKeys = ["description:ru", "description", "description:en"]
    /// Tags that make an object worth carrying as a POI at all.
    private static let poiKeys = ["natural", "amenity", "tourism", "historic", "shop", "leisure",
                          "man_made", "waterway", "mountain_pass", "information"]

    var source: URL
    var destination: URL
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
        try PBFReader(url: source).readInOrder(make: {
            Scan(prefer: prefer, exclude: MakeGPI.parse(exclude))
        }) { part in
            scan.take(part)
            part.clear()
        }
        let points = try scan.resolve(url: source)
        guard !points.isEmpty else { throw Trouble.nothingToWrite }

        let page = Self.codePage(named: codepage)
        // Lossy on purpose: a letter the code page has no room for becomes "?" rather
        // than costing the whole point.
        func encoded(_ text: String) -> [UInt8] {
            CodePage.encode(text, codePage: page, lossy: true) ?? []
        }
        let file = GPIFile.data(
            points: points.map {
                GPIFile.Point(lat: $0.lat, lon: $0.lon, name: encoded($0.name),
                              description: encoded($0.description))
            },
            category: encoded(category),
            codePage: page,
            fileName: destination.lastPathComponent,
            icon: showOnMap ? GPIFile.Icon.dot : nil)
        try file.write(to: destination)

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
    /// First pass: the objects worth carrying, and the node ids the closed ways need.
    struct Scan: OSMSink {
        let prefer: String
        let exclude: (exact: Set<String>, wildcard: Set<String>)

        /// Takes another block's findings: the counts add, and the areas keep their order.
        mutating func take(_ other: Scan) {
            points.append(contentsOf: other.points)
            areaName.append(contentsOf: other.areaName)
            areaDescription.append(contentsOf: other.areaDescription)
            let base = Int32(areaRefs.count)
            areaRefs.append(contentsOf: other.areaRefs)
            for start in other.areaStart.dropFirst() { areaStart.append(base + start) }
            uninformative += other.uninformative
            excluded += other.excluded
        }

        mutating func clear() {
            points.removeAll(keepingCapacity: true)
            areaName.removeAll(keepingCapacity: true)
            areaDescription.removeAll(keepingCapacity: true)
            areaRefs.removeAll(keepingCapacity: true)
            areaStart = [0]
            uninformative = 0
            excluded = 0
        }
        var points: [Point] = []
        var uninformative = 0
        var excluded = 0
        /// Closed ways: their name and description, and where their nodes are to be found.
        var areaName: [String] = []
        var areaDescription: [String] = []
        var areaStart: [Int32] = [0]
        var areaRefs: [Int64] = []

        mutating func node(id: Int64, lat: Double, lon: Double,
                           tags: ArraySlice<Int32>, block: OSMBlock) {
            var pairs: [String: String] = [:]
            var at = tags.startIndex
            while at + 1 < tags.endIndex {
                pairs[block.text(Int(tags[at]))] = block.text(Int(tags[at + 1]))
                at += 2
            }
            if let taken = take(pairs) {
                points.append(Point(lat: lat, lon: lon, name: taken.name,
                                    description: taken.description))
            }
        }

        mutating func way(id: Int64, refs: ArraySlice<Int64>,
                          keys: ArraySlice<Int32>, values: ArraySlice<Int32>, block: OSMBlock) {
            guard refs.count >= 4, refs.first == refs.last else { return }
            var pairs: [String: String] = [:]
            for (i, key) in keys.enumerated() where i < values.count {
                pairs[block.text(Int(key))] = block.text(Int(values[values.startIndex + i]))
            }
            guard let taken = take(pairs) else { return }
            areaName.append(taken.name)
            areaDescription.append(taken.description)
            areaRefs.append(contentsOf: refs)
            areaStart.append(Int32(areaRefs.count))
        }

        /// Whether this object is carried, and under what name.
        private mutating func take(_ tags: [String: String]) -> (name: String, description: String)? {
            guard MakeGPI.poiKeys.contains(where: { tags[$0] != nil }) else { return nil }
            var order = MakeGPI.descriptionKeys
            let wanted = "description:" + prefer
            if let at = order.firstIndex(of: wanted) {
                order.remove(at: at)
                order.insert(wanted, at: 0)
            }
            guard let description = order.compactMap({ tags[$0] })
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { !$0.isEmpty }) else { return nil }

            // Hidden on the map means hidden here. Counted after the description check,
            // so the tally means described entries dropped.
            for key in exclude.wildcard where tags[key] != nil {
                excluded += 1
                return nil
            }
            for pair in exclude.exact {
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2, tags[String(parts[0])] == String(parts[1]) {
                    excluded += 1
                    return nil
                }
            }

            var name = tags["name"] ?? tags["name:ru"] ?? ""
            guard MakeGPI.worthCarrying(description, name) else {
                uninformative += 1
                return nil
            }
            if name.isEmpty {
                // Fall back to what the thing is, so the list is navigable.
                for key in MakeGPI.poiKeys {
                    guard let value = tags[key] else { continue }
                    name = value.replacingOccurrences(of: "_", with: " ")
                    break
                }
            }
            return (name, description)
        }

        /// Second pass: where the closed ways are. Each is placed at the centre of its
        /// bounding box.
        func resolve(url: URL) throws -> [Point] {
            guard !areaName.isEmpty else { return points }
            let places = try NodePlaces.gather(NodePlaces.wantedIDs(from: areaRefs), from: url)

            var out = points
            for i in 0..<areaName.count {
                var minLat = Double.infinity, maxLat = -Double.infinity
                var minLon = Double.infinity, maxLon = -Double.infinity
                for at in Int(areaStart[i])..<Int(areaStart[i + 1]) {
                    guard let point = places.place(of: areaRefs[at]) else { continue }
                    minLat = min(minLat, point.lat); maxLat = max(maxLat, point.lat)
                    minLon = min(minLon, point.lon); maxLon = max(maxLon, point.lon)
                }
                guard minLat.isFinite, minLon.isFinite else { continue }
                out.append(Point(lat: (minLat + maxLat) / 2, lon: (minLon + maxLon) / 2,
                                 name: areaName[i], description: areaDescription[i]))
            }
            return out
        }
    }

}
