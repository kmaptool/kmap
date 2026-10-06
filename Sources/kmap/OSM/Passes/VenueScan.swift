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
        /// Its name, to tell 2 places apart; empty where it has none.
        var name: String = ""
    }

    /// Whether 2 names say these are different places, not 1 mapped twice: both named,
    /// and named otherwise.
    static func differ(_ one: String, _ other: String) -> Bool {
        !one.isEmpty && !other.isEmpty && one != other
    }

    /// Which way ids repeat an enclosing venue, or one already marked by a node.
    static func duplicates(in url: URL, shouldStop: @escaping () -> Bool = { false }) throws -> Set<Int64> {
        // Both passes decode on every core; the joining stays in file order, which is what
        // lets the second one walk the wanted ids instead of searching for each.
        let shape = try readVenueWays(in: url, shouldStop: shouldStop)
        let (places, venues) = try readVenueNodes(in: url, wanted: shape.refs, shouldStop: shouldStop)
        return mark(assemble(shape, places: places), nodes: venues)
    }

    /// First pass over the extract: every closed way carrying a venue tag.
    private static func readVenueWays(in url: URL, shouldStop: @escaping () -> Bool) throws -> Shapes {
        var shape = Shapes()
        try PBFReader(url: url, shouldStop: shouldStop).readInOrder(make: { Shapes() }) { part in
            shape.ids.append(contentsOf: part.ids)
            shape.tags.append(contentsOf: part.tags)
            shape.named.append(contentsOf: part.named)
            shape.names.append(contentsOf: part.names)
            let base = Int32(shape.refs.count)
            shape.refs.append(contentsOf: part.refs)
            for start in part.starts.dropFirst() { shape.starts.append(base + start) }
            part.clear()
        }
        return shape
    }

    /// Second pass: where the ways' member nodes stand, and the venue nodes in their own
    /// right.
    private static func readVenueNodes(
        in url: URL,
        wanted refs: [Int64],
        shouldStop: @escaping () -> Bool
    ) throws -> (NodePlaces, [(tag: String, x: Double, y: Double, name: String)]) {
        var places = NodePlaces(wanted: NodePlaces.wantedIDs(from: refs))
        var venues: [(tag: String, x: Double, y: Double, name: String)] = []
        try PBFReader(url: url, shouldStop: shouldStop).readInOrder(make: { VenueNodes() }) { block in
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
                let maxX = xs.max(), let maxY = ys.max()
            else { continue }
            let box = (minX, minY, maxX, maxY)
            areas.append(
                Area(
                    id: id,
                    seen: i,
                    tag: shape.tags[i],
                    ring: ring,
                    box: box,
                    size: (box.2 - box.0) * (box.3 - box.1),
                    named: shape.named[i],
                    name: shape.names[i]
                )
            )
        }
        return areas
    }

    static func mark(_ areas: [Area], nodes: [(tag: String, x: Double, y: Double, name: String)]) -> Set<Int64> {
        var byTag: [String: [Area]] = [:]
        for area in areas { byTag[area.tag, default: []].append(area) }
        var nodesByTag: [String: [(x: Double, y: Double, name: String)]] = [:]
        for node in nodes { nodesByTag[node.tag, default: []].append((node.x, node.y, node.name)) }

        // Tags do not interact, so the groups are independent and go out to every core;
        // the sets are unioned afterwards, which does not depend on order.
        let tags = byTag.keys.sorted()
        // Read-only from here on, and read from every lane.
        let groups = byTag, points = nodesByTag
        var parts = [Set<Int64>](repeating: [], count: tags.count)
        parts.withUnsafeMutableBufferPointer { slots in
            // Each tag fills only its own slot, which no type can say: nothing is shared.
            nonisolated(unsafe) let slots = slots
            DispatchQueue.concurrentPerform(iterations: tags.count) { i in
                slots[i] = markOne(groups[tags[i]] ?? [], nodes: points[tags[i]] ?? [])
            }
        }
        var marked = Set<Int64>()
        for part in parts { marked.formUnion(part) }
        return marked
    }

    /// One tag's worth: the areas carrying it, and the venue nodes carrying the same tag.
    private static func markOne(_ group: [Area], nodes: [(x: Double, y: Double, name: String)]) -> Set<Int64> {
        var group = group
        // Largest first, and file order between equals -- the enclosing area has to be met
        // before the one it encloses.
        group.sort { $0.size == $1.size ? $0.seen < $1.seen : $0.size > $1.size }
        var marked = Set<Int64>()
        let grid = Grid(group)

        // An area drawn round a POI node carrying the same tag. Read from the node's side:
        // an area is marked if any node falls in it, so the direction does not matter.
        for point in nodes {
            grid.candidates(at: (point.x, point.y)) { at in
                let area = group[at]
                // A named area is kept over an unnamed node: only areas are marked here,
                // and marking it would leave the place without its name.
                guard !marked.contains(area.id), !differ(point.name, area.name),
                    !(area.named && point.name.isEmpty),
                    point.x >= area.box.x0, point.x <= area.box.x1,
                    point.y >= area.box.y0, point.y <= area.box.y1,
                    inside((point.x, point.y), area.ring)
                else { return }
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
                guard !differ(inner.name, outer.name),
                    inner.box.x0 >= outer.box.x0, inner.box.y0 >= outer.box.y0,
                    inner.box.x1 <= outer.box.x1, inner.box.y1 <= outer.box.y1,
                    inside(centre, outer.ring)
                else { return }
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
                let across =
                    (ring[j].x - ring[i].x) * (point.y - ring[i].y)
                    / (ring[j].y - ring[i].y) + ring[i].x
                if point.x < across { within.toggle() }
            }
            j = i
        }
        return within
    }
}
