import Foundation

/// Multipolygon members joined end to end into rings, and the question a tile asks of them.
///
/// A relation can enclose ground it has no node in — an administrative area whose own ways
/// run along one edge only — and a tile inside it would hear nothing about it from its
/// members. So the rings are built and asked directly whether they cover the tile.
extension TileSplitter {
    struct RingBuilder {
        var closed: [[(lat: Int32, lon: Int32)]]
        var openBBox: Area?

        static func rings(of ways: [Int64], refs: [Int64: [Int64]],
                          coords: [Int64: (lat: Int32, lon: Int32)]) -> RingBuilder {
            // Chains of node ids, joined by shared endpoints, either direction.
            var pieces: [[Int64]] = ways.compactMap { refs[$0] }.filter { $0.count >= 2 }
            var closedIDs: [[Int64]] = []
            var open: [[Int64]] = []
            while var chain = pieces.popLast() {
                var grew = true
                while grew {
                    grew = false
                    if chain.first == chain.last { break }
                    for (index, piece) in pieces.enumerated() {
                        if piece.first == chain.last {
                            chain.append(contentsOf: piece.dropFirst())
                        } else if piece.last == chain.last {
                            chain.append(contentsOf: piece.reversed().dropFirst())
                        } else if piece.last == chain.first {
                            chain.insert(contentsOf: piece.dropLast(), at: 0)
                        } else if piece.first == chain.first {
                            chain.insert(contentsOf: piece.reversed().dropLast(), at: 0)
                        } else {
                            continue
                        }
                        pieces.remove(at: index)
                        grew = true
                        break
                    }
                }
                if chain.first == chain.last && chain.count > 3 {
                    closedIDs.append(chain)
                } else {
                    open.append(chain)
                }
            }

            var closed: [[(lat: Int32, lon: Int32)]] = []
            for ring in closedIDs {
                let points = ring.compactMap { coords[$0] }
                if points.count == ring.count {
                    closed.append(points)
                } else {
                    // A ring with a point the extract does not hold cannot be filled,
                    // but it still stands somewhere: it falls back to the box the
                    // open chains take, rather than claiming nothing at all and
                    // leaving a lake's inner tiles never hearing of it.
                    open.append(ring)
                }
            }
            var bbox: Area?
            if !open.isEmpty {
                var minLat = Int32.max, maxLat = Int32.min
                var minLon = Int32.max, maxLon = Int32.min
                for chain in open {
                    for id in chain {
                        guard let p = coords[id] else { continue }
                        minLat = min(minLat, p.lat); maxLat = max(maxLat, p.lat)
                        minLon = min(minLon, p.lon); maxLon = max(maxLon, p.lon)
                    }
                }
                if minLat <= maxLat {
                    bbox = Area(minLat: minLat, minLon: minLon,
                                maxLat: maxLat, maxLon: maxLon)
                }
            }
            return RingBuilder(closed: closed, openBBox: bbox)
        }

        /// Does the multipolygon claim this tile -- ring crossing it, or swallowing it?
        func claims(_ area: Area) -> Bool {
            if let bbox = openBBox,
               bbox.minLat < area.maxLat, bbox.maxLat >= area.minLat,
               bbox.minLon < area.maxLon, bbox.maxLon >= area.minLon {
                return true
            }
            let centreLat = Int64(area.minLat) + Int64(area.maxLat - area.minLat) / 2
            let centreLon = Int64(area.minLon) + Int64(area.maxLon - area.minLon) / 2
            var inside = false
            for ring in closed {
                for i in 0..<(ring.count - 1) {
                    let a = ring[i], b = ring[i + 1]
                    // Any edge touching the tile rectangle claims it.
                    if segmentMeets(a, b, area) { return true }
                    // Even-odd count against the tile centre, all rings together, so holes
                    // uncount what their outer ring counted.
                    if (Int64(a.lat) > centreLat) != (Int64(b.lat) > centreLat) {
                        let t = Double(centreLat - Int64(a.lat)) / Double(Int64(b.lat) - Int64(a.lat))
                        let x = Double(a.lon) + t * Double(Int64(b.lon) - Int64(a.lon))
                        if Double(centreLon) < x { inside.toggle() }
                    }
                }
            }
            return inside
        }

        private func segmentMeets(_ a: (lat: Int32, lon: Int32),
                                  _ b: (lat: Int32, lon: Int32), _ rect: Area) -> Bool {
            // Trivial rejection first: both ends on the same outside of one edge.
            if a.lat < rect.minLat && b.lat < rect.minLat { return false }
            if a.lat >= rect.maxLat && b.lat >= rect.maxLat { return false }
            if a.lon < rect.minLon && b.lon < rect.minLon { return false }
            if a.lon >= rect.maxLon && b.lon >= rect.maxLon { return false }
            // Either end inside settles it.
            if rect.contains(lat: a.lat, lon: a.lon) { return true }
            if rect.contains(lat: b.lat, lon: b.lon) { return true }
            // Otherwise test the segment against each rectangle edge by orientation.
            let corners = [(rect.minLat, rect.minLon), (rect.minLat, rect.maxLon),
                           (rect.maxLat, rect.maxLon), (rect.maxLat, rect.minLon)]
            func side(_ p: (Int32, Int32)) -> Int {
                let cross = Int64(b.lon - a.lon) * Int64(p.0 - a.lat)
                    - Int64(b.lat - a.lat) * Int64(p.1 - a.lon)
                return cross == 0 ? 0 : (cross > 0 ? 1 : -1)
            }
            let sides = corners.map(side)
            // All four corners strictly one side of the segment's line: no crossing.
            if sides.allSatisfy({ $0 > 0 }) || sides.allSatisfy({ $0 < 0 }) { return false }
            // The segment's line crosses the rectangle, and the bbox overlap above says the
            // segment's extent reaches it.
            return true
        }
    }
}
