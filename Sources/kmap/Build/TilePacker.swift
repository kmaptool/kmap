import Foundation

/// Which of the compiled tiles go into which output file, and what each file is called.
/// Pure arithmetic over tile weights and bounding boxes; touches no files.
struct TilePacker {
    /// A compiled tile: how big it came out and what ground it covers.
    struct Tile {
        var id: String
        var bbox: BBox
        var bytes: Int64
    }

    /// A file to write, named, holding the tiles at these positions in the input.
    struct Group {
        var name: String
        var members: [Int]
    }

    var mode: SplitMode
    var axis: SplitAxis
    /// The map's own name, which the output files are named after.
    var slug: String
    /// Regions in the map, for the per-region and per-country splits.
    var regions: [Region] = []
    /// Which country each region sits in, for the per-country split.
    var countryOf: [String: String] = [:]

    func groups(_ tiles: [Tile], upTo limit: Int64) -> [Group] {
        // Ordered along the map's longer side, so each file holds ground that joins up.
        let order = tiles.indices.sorted { a, b in
            let first = axis == .longitude ? (tiles[a].bbox.minLon + tiles[a].bbox.maxLon)
                                           : (tiles[a].bbox.minLat + tiles[a].bbox.maxLat)
            let second = axis == .longitude ? (tiles[b].bbox.minLon + tiles[b].bbox.maxLon)
                                            : (tiles[b].bbox.minLat + tiles[b].bbox.maxLat)
            if first == second { return tiles[a].id < tiles[b].id }
            return first < second
        }
        guard !order.isEmpty else { return [] }

        func named(_ chunks: [[Int]]) -> [Group] {
            let names = partNames(count: chunks.count)
            return chunks.enumerated().map { index, chunk in
                Group(name: index < names.count ? names[index] : "\(slug)-part\(index + 1)",
                      members: chunk)
            }
        }

        switch mode {
        case .fitCard:
            return named(pack(order, tiles, upTo: limit))
        case .count(let wanted):
            return named(share(order, tiles, into: wanted))
        case .perRegion, .perCountry:
            var keys: [String] = []
            var byKey: [String: [Int]] = [:]
            for index in order {
                let key = fileKey(for: tiles[index])
                if byKey[key] == nil { keys.append(key) }
                byKey[key, default: []].append(index)
            }
            var out: [Group] = []
            for key in keys {
                // A single region can still exceed the limit, so it is packed as well.
                let chunks = pack(byKey[key] ?? [], tiles, upTo: limit)
                if chunks.count == 1 {
                    out.append(Group(name: key, members: chunks[0]))
                } else {
                    for (index, chunk) in chunks.enumerated() {
                        out.append(Group(name: "\(key)-part\(index + 1)", members: chunk))
                    }
                }
            }
            return out
        }
    }

    /// Names for the produced files: the slug alone, a pair named along the split axis, or
    /// numbered parts.
    func partNames(count: Int) -> [String] {
        guard count > 1 else { return [slug] }
        if count == 2 {
            return axis == .longitude ? ["\(slug)-west", "\(slug)-east"]
                                      : ["\(slug)-south", "\(slug)-north"]
        }
        return (1...count).map { "\(slug)-part\($0)" }
    }

    /// Fills one file at a time up to the limit, in the order given.
    private func pack(_ order: [Int], _ tiles: [Tile], upTo limit: Int64) -> [[Int]] {
        guard !order.isEmpty else { return [] }
        var out: [[Int]] = []
        var current: [Int] = []
        var size: Int64 = 0
        for index in order {
            if !current.isEmpty, size + tiles[index].bytes > limit {
                out.append(current)
                current = []
                size = 0
            }
            current.append(index)
            size += tiles[index].bytes
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Cuts into a given number of files of roughly equal weight.
    private func share(_ order: [Int], _ tiles: [Tile], into count: Int) -> [[Int]] {
        let wanted = max(1, min(count, order.count))
        guard wanted > 1 else { return [order] }
        let total = order.reduce(Int64(0)) { $0 + max(1, tiles[$1].bytes) }
        let target = Double(total) / Double(wanted)

        var out: [[Int]] = []
        var current: [Int] = []
        var size: Double = 0
        for index in order {
            current.append(index)
            size += Double(max(1, tiles[index].bytes))
            let remaining = order.count - (out.reduce(0) { $0 + $1.count } + current.count)
            // Close this file once it has its share, never leaving a later one empty.
            if out.count < wanted - 1, size >= target, remaining >= wanted - out.count - 1 {
                out.append(current)
                current = []
                size = 0
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// The region, or country, a tile belongs to. Tile boundaries ignore borders, so a tile
    /// goes with whichever region contains its centre, or failing that the nearest one.
    private func fileKey(for tile: Tile) -> String {
        let lat = (tile.bbox.minLat + tile.bbox.maxLat) / 2
        let lon = (tile.bbox.minLon + tile.bbox.maxLon) / 2
        var nearest: (id: String, distance: Double)?
        var found: String?
        for region in regions {
            for box in region.boxes where box.isValid {
                if box.contains(lat: lat, lon: lon) { found = region.id; break }
                let away = box.distance(toLat: lat, lon: lon)
                if away < (nearest?.distance ?? .infinity) { nearest = (region.id, away) }
            }
            if found != nil { break }
        }
        let regionID = found ?? nearest?.id ?? regions.first?.id ?? slug
        if case .perCountry = mode {
            return FileTools.slugify(countryOf[regionID] ?? regionID)
        }
        return FileTools.slugify(regionID)
    }
}
