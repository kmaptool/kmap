import Foundation

extension MakeGPI {
    /// First pass: the objects worth carrying, and the node ids the closed ways need.
    struct Scan: OSMSink {
        private static let descriptionKeys = ["description:ru", "description", "description:en"]
        /// Tags that make an object worth carrying as a POI at all.
        private static let poiKeys = [
            "natural", "amenity", "tourism", "historic", "shop", "leisure",
            "man_made", "waterway", "mountain_pass", "information"
        ]
        private static let poiKeySet = Set(poiKeys)

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

        mutating func node(
            id: Int64,
            lat: Double,
            lon: Double,
            tags: ArraySlice<Int32>,
            block: OSMBlock
        ) {
            // Most tagged nodes are not points of interest: the keys are looked at before
            // any dictionary is built for them.
            var wanted = false
            var at = tags.startIndex
            while at + 1 < tags.endIndex {
                if Self.poiKeySet.contains(block.text(Int(tags[at]))) { wanted = true; break }
                at += 2
            }
            guard wanted else { return }
            var pairs: [String: String] = [:]
            at = tags.startIndex
            while at + 1 < tags.endIndex {
                pairs[block.text(Int(tags[at]))] = block.text(Int(tags[at + 1]))
                at += 2
            }
            if let taken = take(pairs) {
                points.append(
                    Point(
                        lat: lat,
                        lon: lon,
                        name: taken.name,
                        description: taken.description
                    )
                )
            }
        }

        mutating func way(
            id: Int64,
            refs: ArraySlice<Int64>,
            keys: ArraySlice<Int32>,
            values: ArraySlice<Int32>,
            block: OSMBlock
        ) {
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
            guard Self.poiKeys.contains(where: { tags[$0] != nil }) else { return nil }
            var order = Self.descriptionKeys
            let wanted = "description:" + prefer
            if let at = order.firstIndex(of: wanted) {
                order.remove(at: at)
                order.insert(wanted, at: 0)
            }
            guard
                let description = order.compactMap({ tags[$0] })
                    .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                    .first(where: { !$0.isEmpty })
            else { return nil }

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
                for key in Self.poiKeys {
                    guard let value = tags[key] else { continue }
                    name = value.replacingOccurrences(of: "_", with: " ")
                    break
                }
            }
            return (name, description)
        }

        /// Second pass: where the closed ways are. Each is placed at the centre of its
        /// bounding box.
        func resolve(urls: [URL]) throws -> [Point] {
            guard !areaName.isEmpty else { return points }
            let wanted = NodePlaces.wantedIDs(from: areaRefs)
            let gathered = try urls.map { try NodePlaces.gather(wanted, from: $0) }
            func placeOf(_ id: Int64) -> (lat: Double, lon: Double)? {
                for places in gathered { if let place = places.place(of: id) { return place } }
                return nil
            }

            var out = points
            for i in 0..<areaName.count {
                var minLat = Double.infinity, maxLat = -Double.infinity
                var minLon = Double.infinity, maxLon = -Double.infinity
                for at in Int(areaStart[i])..<Int(areaStart[i + 1]) {
                    guard let point = placeOf(areaRefs[at]) else { continue }
                    minLat = min(minLat, point.lat); maxLat = max(maxLat, point.lat)
                    minLon = min(minLon, point.lon); maxLon = max(maxLon, point.lon)
                }
                guard minLat.isFinite, minLon.isFinite else { continue }
                out.append(
                    Point(
                        lat: (minLat + maxLat) / 2,
                        lon: (minLon + maxLon) / 2,
                        name: areaName[i],
                        description: areaDescription[i]
                    )
                )
            }
            return out
        }
    }
}
