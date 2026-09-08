import Foundation

/// Areas that merely repeat a venue already on the map.
///
/// OSM often maps a place twice, on the site and on the building in it, and
/// `--add-pois-to-areas` turns both into a POI. A style rule sees only the tags of the
/// object in front of it, so the containment test has to happen here, on the geometry.
struct VenueScan {
    /// Keys whose areas mkgmap turns into a POI, and so can put a second icon on one that
    /// is already there.
    static let keys = ["amenity", "shop", "tourism", "office", "healthcare"]
    /// The same list as a lookup, since it is asked of every tag of every object.
    private static let keyRank: [String: Int] = Dictionary(
        uniqueKeysWithValues: keys.enumerated().map { ($1, $0) })

    struct Area {
        var id: Int64
        /// Where it stood in the file. Swift's sort is not stable, so areas of equal size
        /// are ordered by this to keep the result the same from run to run.
        var seen: Int
        var tag: String
        var ring: [(x: Double, y: Double)]
        var box: (x0: Double, y0: Double, x1: Double, y1: Double)
        var size: Double
        var named: Bool
    }

    /// Which way ids repeat an enclosing venue, or one already marked by a node.
    static func duplicates(in url: URL) throws -> Set<Int64> {
        // Both passes decode on every core; the joining stays in file order, which is what
        // lets the second one walk the wanted ids instead of searching for each.
        let shape = try readVenueWays(in: url)
        let (places, venues) = try readVenueNodes(in: url, wanted: shape.refs)
        return mark(assemble(shape, places: places), nodes: venues)
    }

    /// First pass over the extract: every closed way carrying a venue tag.
    private static func readVenueWays(in url: URL) throws -> Shapes {
        var shape = Shapes()
        try PBFReader(url: url).readInOrder(make: { Shapes() }) { part in
            shape.ids.append(contentsOf: part.ids)
            shape.tags.append(contentsOf: part.tags)
            shape.named.append(contentsOf: part.named)
            let base = Int32(shape.refs.count)
            shape.refs.append(contentsOf: part.refs)
            for start in part.starts.dropFirst() { shape.starts.append(base + start) }
            part.clear()
        }
        return shape
    }

    /// Second pass: where the ways' member nodes stand, and the venue nodes in their own
    /// right.
    private static func readVenueNodes(in url: URL, wanted refs: [Int64]) throws
        -> (NodePlaces, [(tag: String, x: Double, y: Double)]) {
        var places = NodePlaces(wanted: NodePlaces.wantedIDs(from: refs))
        var venues: [(tag: String, x: Double, y: Double)] = []
        try PBFReader(url: url).readInOrder(make: { VenueNodes() }) { block in
            places.take(block.nodes)
            venues.append(contentsOf: block.venues)
            block.clear()
        }
        return (places, venues)
    }

    /// Joins the two passes: each way's refs resolved to a ring, with its bounding box.
    /// A way whose ring cannot be resolved to at least a triangle is dropped.
    private static func assemble(_ shape: Shapes, places: NodePlaces) -> [Area] {
        var areas: [Area] = []
        for (i, id) in shape.ids.enumerated() {
            let range = Int(shape.starts[i])..<Int(shape.starts[i + 1])
            var ring: [(x: Double, y: Double)] = []
            ring.reserveCapacity(range.count)
            for at in range {
                guard let point = places.place(of: shape.refs[at]) else { continue }
                ring.append((point.lon, point.lat))
            }
            guard ring.count >= 4 else { continue }
            let xs = ring.map(\.x), ys = ring.map(\.y)
            guard let minX = xs.min(), let minY = ys.min(),
                  let maxX = xs.max(), let maxY = ys.max() else { continue }
            let box = (minX, minY, maxX, maxY)
            areas.append(Area(id: id, seen: i, tag: shape.tags[i], ring: ring, box: box,
                              size: (box.2 - box.0) * (box.3 - box.1), named: shape.named[i]))
        }
        return areas
    }

    static func mark(_ areas: [Area], nodes: [(tag: String, x: Double, y: Double)]) -> Set<Int64> {
        var byTag: [String: [Area]] = [:]
        for area in areas { byTag[area.tag, default: []].append(area) }
        var nodesByTag: [String: [(x: Double, y: Double)]] = [:]
        for node in nodes { nodesByTag[node.tag, default: []].append((node.x, node.y)) }

        // Tags do not interact, so the groups are independent and go out to every core;
        // the sets are unioned afterwards, which does not depend on order.
        let tags = byTag.keys.sorted()
        var parts = [Set<Int64>](repeating: [], count: tags.count)
        parts.withUnsafeMutableBufferPointer { slots in
            DispatchQueue.concurrentPerform(iterations: tags.count) { i in
                slots[i] = markOne(byTag[tags[i]] ?? [], nodes: nodesByTag[tags[i]] ?? [])
            }
        }
        var marked = Set<Int64>()
        for part in parts { marked.formUnion(part) }
        return marked
    }

    /// One tag's worth: the areas carrying it, and the venue nodes carrying the same tag.
    private static func markOne(_ group: [Area], nodes: [(x: Double, y: Double)]) -> Set<Int64> {
        var group = group
        // Largest first, and file order between equals -- the enclosing area has to be met
        // before the one it encloses.
        group.sort { $0.size == $1.size ? $0.seen < $1.seen : $0.size > $1.size }
        var marked = Set<Int64>()
        let grid = Grid(group)

        // An area drawn round a POI node carrying the same tag. Read from the node's side:
        // an area is marked if any node falls in it, so the direction does not matter.
        for point in nodes {
            grid.candidates(at: point) { at in
                let area = group[at]
                guard !marked.contains(area.id),
                      point.x >= area.box.x0, point.x <= area.box.x1,
                      point.y >= area.box.y0, point.y <= area.box.y1,
                      inside(point, area.ring) else { return }
                marked.insert(area.id)
            }
        }

        // An area inside another with the same tag. Only the larger areas met earlier can
        // enclose it, and an enclosing box always covers this box's lower left corner.
        for (j, inner) in group.enumerated() {
            let centre = ((inner.box.x0 + inner.box.x1) / 2, (inner.box.y0 + inner.box.y1) / 2)
            grid.candidates(at: (inner.box.x0, inner.box.y0)) { i in
                guard i < j else { return }
                let outer = group[i]
                // Bounding boxes settle nearly every pair.
                guard inner.box.x0 >= outer.box.x0, inner.box.y0 >= outer.box.y0,
                      inner.box.x1 <= outer.box.x1, inner.box.y1 <= outer.box.y1,
                      inside(centre, outer.ring) else { return }
                // The enclosing area usually carries the name, so the inner one goes; where
                // the naming runs the other way, the named one is kept.
                marked.insert(inner.named && !outer.named ? outer.id : inner.id)
            }
        }
        return marked
    }

    /// Whether a point lies inside a ring, by ray casting.
    static func inside(_ point: (x: Double, y: Double), _ ring: [(x: Double, y: Double)]) -> Bool {
        var within = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            if (ring[i].y > point.y) != (ring[j].y > point.y) {
                let across = (ring[j].x - ring[i].x) * (point.y - ring[i].y)
                    / (ring[j].y - ring[i].y) + ring[i].x
                if point.x < across { within.toggle() }
            }
            j = i
        }
        return within
    }

    /// First pass: the closed ways carrying a venue tag.
    private struct Shapes: OSMSink {
        // Ways only: there is no relation handler here, and asking for relations unpacks
        // every one in the extract into the default no-op sink.
        let wantedParts: OSMParts = .ways

        var ids: [Int64] = []
        var tags: [String] = []
        var named: [Bool] = []
        var starts: [Int32] = [0]
        var refs: [Int64] = []

        mutating func clear() {
            ids.removeAll(keepingCapacity: true)
            tags.removeAll(keepingCapacity: true)
            named.removeAll(keepingCapacity: true)
            starts = [0]
            refs.removeAll(keepingCapacity: true)
        }

        mutating func way(id: Int64, refs list: ArraySlice<Int64>,
                          keys: ArraySlice<Int32>, values: ArraySlice<Int32>, block: OSMBlock) {
            guard list.count >= 4, list.first == list.last else { return }
            // A place can carry more than one of these keys, so the key is chosen by the
            // order of `VenueScan.keys`, not by the order the file stores the tags in.
            var present: [String: String] = [:]
            var hasName = false
            for (i, key) in keys.enumerated() {
                guard i < values.count else { break }
                let word = block.text(Int(key))
                if word == "name" { hasName = true }
                if VenueScan.keys.contains(word) {
                    present[word] = block.text(Int(values[values.startIndex + i]))
                }
            }
            var found: String?
            for key in VenueScan.keys {
                if let value = present[key] {
                    found = key + "=" + value
                    break
                }
            }
            guard let found else { return }
            ids.append(id)
            tags.append(found)
            named.append(hasName)
            refs.append(contentsOf: list)
            starts.append(Int32(refs.count))
        }
    }

    /// Second pass: the venue nodes in their own right, and the raw ids and places the
    /// ways of the first pass refer to.
    private struct VenueNodes: OSMSink {
        let wantedParts: OSMParts = .nodes

        var nodes = BlockNodes()
        var venues: [(tag: String, x: Double, y: Double)] = []

        mutating func node(id: Int64, lat latitude: Double, lon longitude: Double,
                           tags: ArraySlice<Int32>, block: OSMBlock) {
            nodes.node(id: id, lat: latitude, lon: longitude, tags: tags, block: block)

            // The key is chosen by the order of `VenueScan.keys`. Written without a
            // dictionary: this runs on every node of the extract.
            var bestKey = Int.max
            var bestValue = ""
            var at = tags.startIndex
            while at + 1 < tags.endIndex {
                let key = block.text(Int(tags[at]))
                if let rank = VenueScan.keyRank[key], rank < bestKey {
                    bestKey = rank
                    bestValue = block.text(Int(tags[at + 1]))
                }
                at += 2
            }
            if bestKey != Int.max {
                venues.append((VenueScan.keys[bestKey] + "=" + bestValue, longitude, latitude))
            }
        }

        mutating func clear() {
            nodes.clear()
            venues.removeAll(keepingCapacity: true)
        }
    }
}
