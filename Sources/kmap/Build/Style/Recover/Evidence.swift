import Foundation

/// The OSM sources identified for each foreign type code.
///
/// An entry pairs a map element whose vertex chain matched exactly one OSM way or node
/// with that source's tags. Two distinct clean matches settle a code, one is flagged.
struct Evidence: Sendable {
    struct ForCode {
        var kind: ElementDumper.Kind
        var type: Int
        /// Identified sources and their tags, keyed by OSM id, so one way drawn on five
        /// zoom levels counts once.
        var sources: [Int64: [String: String]] = [:]
        var elements = 0
        var unmatched = 0
        var ambiguous = 0
        /// How many identified elements of this code were drawn at each resolution.
        /// A style with a second, thinner set of road types for the zoomed-out levels
        /// shows here as a code living only at the coarse end.
        var resolutions: [Int: Int] = [:]
        /// The zoom each identified source was seen at, so a meaning can be read per
        /// zoom rather than per code: one code may draw two meanings, and one meaning
        /// may be drawn by a different code at every zoom.
        var sourceZoom: [Int64: Int16] = [:]
        /// The ground each identified area covers, in map units squared: a number of
        /// ours shared by two meanings wears the picture of the one covering more.
        var extent: [Int64: Double] = [:]
    }

    /// Keyed by `slot`, a packed integer rather than a string: the key is built once per
    /// map element, while the string key is needed only per line of the report.
    private var table: [Int: ForCode] = [:]

    var codes: [String: ForCode] {
        var out: [String: ForCode] = [:]
        out.reserveCapacity(table.count)
        for code in table.values { out[Self.key(code.kind, code.type)] = code }
        return out
    }

    init() {}

    /// Hand-built evidence, for exercising derivation without a map.
    init(codes: [String: ForCode]) {
        for code in codes.values { table[Self.slot(code.kind, code.type)] = code }
    }

    static func key(_ kind: ElementDumper.Kind, _ type: Int) -> String {
        "\(kind.rawValue)\(String(type, radix: 16))"
    }

    private static func slot(_ kind: ElementDumper.Kind, _ type: Int) -> Int {
        (kind.slot << 32) | type
    }

    /// Folds one worker's tally into this one. Counts add; sources are keyed by OSM id,
    /// so the same source seen by two workers stays one.
    /// The resolutions a code was seen at, coarsest first.
    static func span(_ code: ForCode) -> (lowest: Int, highest: Int)? {
        guard let low = code.resolutions.keys.min(),
              let high = code.resolutions.keys.max() else { return nil }
        return (low, high)
    }

    mutating func merge(_ other: Evidence) {
        for (key, part) in other.table {
            guard var mine = table[key] else { table[key] = part; continue }
            mine.elements += part.elements
            mine.unmatched += part.unmatched
            mine.ambiguous += part.ambiguous
            for (id, tags) in part.sources { mine.sources[id] = tags }
            for (id, area) in part.extent { mine.extent[id, default: 0] += area }
            for (id, zoom) in part.sourceZoom {
                // The coarsest sighting: what a stroke is for shows at the far end.
                mine.sourceZoom[id] = min(mine.sourceZoom[id] ?? zoom, zoom)
            }
            mine.resolutions.merge(part.resolutions, uniquingKeysWith: +)
            table[key] = mine
        }
    }

    /// What one extract said about one element, ranked: the best answer any extract
    /// gave stands, and a name beats a doubt.
    enum Match: UInt8 {
        case unmatched = 0
        /// More than one candidate left standing.
        case ambiguous = 1
        case matched = 2
    }

    /// Reads one element against one extract and returns the outcome. The element,
    /// unmatched and ambiguous counts are kept by `tally` instead, since an element is
    /// read once per extract and would otherwise be counted several times.
    @discardableResult
    mutating func record(_ element: ElementDumper.Element, chain: ArraySlice<UInt64>,
                         in index: GroundIndex, resolution: Int? = nil) -> Match {
        let key = Self.slot(element.kind, element.type)
        switch element.kind {
        case .point:
            guard let cell = chain.first,
                  let slots = index.nodesByCell[cell] else { return .unmatched }
            // Several tagged nodes in one 2.4 m cell cannot be told apart.
            guard slots.count == 1 else { return .ambiguous }
            let node = index.nodes[Int(slots[0])]
            // Mutated in place through the defaulting subscript: reading the struct out
            // and writing it back copies its sources dictionary twice per element.
            table[key, default: ForCode(kind: element.kind, type: element.type)]
                .sources[node.id] = node.tags
            if let resolution {
                table[key]?.resolutions[resolution, default: 0] += 1
                let held = table[key]?.sourceZoom[node.id]
                table[key]?.sourceZoom[node.id] = min(held ?? Int16(resolution),
                                                      Int16(resolution))
            }
            return .matched
        case .line, .area:
            guard let slot = ElementMatcher.way(of: chain, in: index,
                                                ring: element.kind == .area)
            else { return .unmatched }
            let way = index.ways[Int(slot)]
            table[key, default: ForCode(kind: element.kind, type: element.type)]
                .sources[way.id] = index.tags(ofWay: slot)
            if element.kind == .area {
                table[key]?.extent[way.id, default: 0] += GarminGrid.area(of: chain)
            }
            if let resolution {
                table[key]?.resolutions[resolution, default: 0] += 1
                let held = table[key]?.sourceZoom[way.id]
                table[key]?.sourceZoom[way.id] = min(held ?? Int16(resolution),
                                                     Int16(resolution))
            }
            return .matched
        }
    }

    /// One identified source, recorded directly: the coarse pass names its ways
    /// without going through `record`'s per-cell machinery.
    mutating func witness(kind: ElementDumper.Kind, type: Int, way: Int64,
                          tags: [String: String], resolution: Int? = nil) {
        table[Self.slot(kind, type), default: ForCode(kind: kind, type: type)]
            .sources[way] = tags
        if let resolution {
            table[Self.slot(kind, type)]?.resolutions[resolution, default: 0] += 1
            let held = table[Self.slot(kind, type)]?.sourceZoom[way]
            table[Self.slot(kind, type)]?.sourceZoom[way]
                = min(held ?? Int16(resolution), Int16(resolution))
        }
    }

    /// Counts every element of the map once, taking each element's best outcome across
    /// all extracts from `matches`.
    mutating func tally(_ dump: ElementDumper.Dump, matches: UnsafeBufferPointer<UInt8>) {
        for at in 0..<dump.count {
            let element = dump.elements[at]
            let key = Self.slot(element.kind, element.type)
            table[key, default: ForCode(kind: element.kind, type: element.type)].elements += 1
            switch Match(rawValue: matches[at]) ?? .unmatched {
            case .matched: break
            case .ambiguous: table[key]?.ambiguous += 1
            case .unmatched: table[key]?.unmatched += 1
            }
        }
    }
}
