import Foundation

extension MakeGPI {
    /// First pass: the objects worth carrying, and the node ids the closed ways need.
    struct Scan: OSMSink {
        private static let descriptionKeys = ["description:ru", "description", "description:en"]
        /// Tags that make an object worth carrying as a POI at all.
        private static let poiKeys = [
            "natural", "amenity", "tourism", "historic", "shop", "leisure",
            "man_made", "waterway", "mountain_pass", "information",
            "office", "craft", "aerialway", "place"
        ]

        let prefer: String
        let exclude: (exact: Set<String>, wildcard: Set<String>)

        /// Takes another block's findings: the counts add, and the areas keep their order.
        mutating func take(_ other: Scan) {
            points.append(contentsOf: other.points)
            areaName.append(contentsOf: other.areaName)
            areaWay.append(contentsOf: other.areaWay)
            areaDescription.append(contentsOf: other.areaDescription)
            let base = Int32(areaRefs.count)
            areaRefs.append(contentsOf: other.areaRefs)
            for start in other.areaStart.dropFirst() { areaStart.append(base + start) }
            uninformative += other.uninformative
            excluded += other.excluded
            relationName.append(contentsOf: other.relationName)
            relationDescription.append(contentsOf: other.relationDescription)
            relationOuters.append(contentsOf: other.relationOuters)
            relationInners.append(contentsOf: other.relationInners)
        }

        mutating func clear() {
            points.removeAll(keepingCapacity: true)
            areaName.removeAll(keepingCapacity: true)
            areaWay.removeAll(keepingCapacity: true)
            areaDescription.removeAll(keepingCapacity: true)
            areaRefs.removeAll(keepingCapacity: true)
            areaStart = [0]
            uninformative = 0
            excluded = 0
            relationName.removeAll(keepingCapacity: true)
            relationDescription.removeAll(keepingCapacity: true)
            relationOuters.removeAll(keepingCapacity: true)
            relationInners.removeAll(keepingCapacity: true)
            wayIDs = nil
        }
        var points: [Point] = []
        var uninformative = 0
        var excluded = 0
        /// Closed ways: their id, name and description, and where their nodes are to be found.
        var areaWay: [Int64] = []
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
            // Most tagged nodes are not points of interest, and most that are carry no
            // description: both are asked of the keys before any dictionary is built.
            var interesting = false, described = false
            var at = tags.startIndex
            while at + 1 < tags.endIndex {
                let key = Int(tags[at])
                if key < keyKinds.count {
                    interesting = interesting || keyKinds[key] == .interest
                    described = described || keyKinds[key] == .description
                }
                at += 2
            }
            guard interesting, described else { return }
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

        /// The lowest and highest way id in this block, for a second look at only the
        /// blocks that can hold a multipolygon's outer ways.
        var wayIDs: ClosedRange<Int64>?

        mutating func way(
            id: Int64,
            refs: ArraySlice<Int64>,
            keys: ArraySlice<Int32>,
            values: ArraySlice<Int32>,
            block: OSMBlock
        ) {
            wayIDs = wayIDs.map { min($0.lowerBound, id)...max($0.upperBound, id) } ?? id...id
            guard refs.count >= 4, refs.first == refs.last else { return }
            guard isCandidate(keys) else { return }
            var pairs: [String: String] = [:]
            for (i, key) in keys.enumerated() where i < values.count {
                pairs[block.text(Int(key))] = block.text(Int(values[values.startIndex + i]))
            }
            guard let taken = take(pairs) else { return }
            areaWay.append(id)
            areaName.append(taken.name)
            areaDescription.append(taken.description)
            areaRefs.append(contentsOf: refs)
            areaStart.append(Int32(areaRefs.count))
        }

        /// Multipolygons carried: their name and description, and their outer ways, read
        /// in a pass of their own as the ways come before the relations in a file.
        var relationName: [String] = []
        var relationDescription: [String] = []
        var relationOuters: [[Int64]] = []
        var relationInners: [[Int64]] = []
        /// The multipolygons, once their ways are read: outer and inner rings by node id.
        var polygonName: [String] = []
        var polygonDescription: [String] = []
        var polygonRings: [(outers: [[Int64]], inners: [[Int64]])] = []
        /// The multipolygons each outer way belongs to.
        var polygonsOf: [Int64: [Int]] = [:]

        mutating func relation(
            id: Int64,
            memberKinds: ArraySlice<Int32>,
            memberIDs: ArraySlice<Int64>,
            memberRoles: ArraySlice<Int32>,
            keys: ArraySlice<Int32>,
            values: ArraySlice<Int32>,
            block: OSMBlock
        ) {
            // Most relations are routes, boundaries and restrictions: told apart by their
            // type alone, before any of their tags is read into a dictionary.
            var multipolygon = false
            for (i, key) in keys.enumerated() where i < values.count {
                guard let name = block.strings.bytes(Int(key)), name.elementsEqual("type".utf8) else { continue }
                multipolygon =
                    block.strings.bytes(Int(values[values.startIndex + i]))?.elementsEqual("multipolygon".utf8) ?? false
                break
            }
            guard multipolygon, isCandidate(keys) else { return }
            var pairs: [String: String] = [:]
            for (i, key) in keys.enumerated() where i < values.count {
                pairs[block.text(Int(key))] = block.text(Int(values[values.startIndex + i]))
            }
            guard let taken = take(pairs) else { return }
            var outers: [Int64] = [], inners: [Int64] = []
            for at in memberKinds.indices where memberKinds[at] == 1 {
                let role = block.text(Int(memberRoles[memberRoles.startIndex + (at - memberKinds.startIndex)]))
                let way = memberIDs[memberIDs.startIndex + (at - memberKinds.startIndex)]
                if role == "outer" || role.isEmpty { outers.append(way) } else if role == "inner" { inners.append(way) }
            }
            guard !outers.isEmpty else { return }
            relationName.append(taken.name)
            relationDescription.append(taken.description)
            relationOuters.append(outers)
            relationInners.append(inners)
        }

        /// What each entry of this block's string table is as a key, found once as the
        /// block begins: then a node's keys are looked up, not spelled out.
        private enum KeyKind { case other, interest, description }
        private var keyKinds: [KeyKind] = []
        private static let interestBytes = poiKeys.map { Array($0.utf8) }
        private static let descriptionBytes = descriptionKeys.map { Array($0.utf8) }

        mutating func begin(_ block: OSMBlock) {
            let strings = block.strings
            keyKinds = (0..<strings.count).map { at in
                guard let bytes = strings.bytes(at), bytes.count >= 4, bytes.count <= 14 else { return .other }
                if Self.interestBytes.contains(where: { $0.count == bytes.count && bytes.elementsEqual($0) }) {
                    return .interest
                }
                if Self.descriptionBytes.contains(where: { $0.count == bytes.count && bytes.elementsEqual($0) }) {
                    return .description
                }
                return .other
            }
        }

        /// Whether these keys name a point of interest and a description, both of which
        /// a carried object has.
        private func isCandidate(_ keys: ArraySlice<Int32>) -> Bool {
            var interesting = false, described = false
            for key in keys where Int(key) < keyKinds.count {
                interesting = interesting || keyKinds[Int(key)] == .interest
                described = described || keyKinds[Int(key)] == .description
            }
            return interesting && described
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

            // In the map's own language where OSM has it.
            var name = tags["name:" + prefer] ?? tags["name"] ?? tags["name:ru"] ?? ""
            guard MakeGPI.worthCarrying(description, name) else {
                uninformative += 1
                return nil
            }
            if name.isEmpty {
                // Fall back to what the thing is, so the list is navigable.
                // In Russian where the map is, as its labels for the unnamed are.
                for key in Self.poiKeys {
                    guard let value = tags[key] else { continue }
                    name =
                        (prefer == "ru" ? MakeGPI.russianName(key: key, value: value) : nil)
                        ?? value.replacingOccurrences(of: "_", with: " ")
                    break
                }
            }
            return (name, description)
        }

        /// The multipolygons' rings, joined from their ways. Relations come after ways in a
        /// file, so the outer ways are read in a second look at only the blocks that can hold
        /// them, which `blobWays` names per file.
        mutating func addMultipolygons(urls: [URL], blobWays: [[ClosedRange<Int64>?]]) throws {
            guard !relationOuters.isEmpty else { return }
            let wanted = Array(Set(relationOuters.joined()).union(relationInners.joined())).sorted()
            func holdsWanted(_ range: ClosedRange<Int64>) -> Bool {
                var low = 0, high = wanted.count
                while low < high {
                    let middle = (low + high) / 2
                    if wanted[middle] < range.lowerBound { low = middle + 1 } else { high = middle }
                }
                return low < wanted.count && wanted[low] <= range.upperBound
            }
            var pieces: [Int64: [Int64]] = [:]
            for (file, url) in urls.enumerated() {
                let ranges = file < blobWays.count ? blobWays[file] : []
                let chosen = Set(ranges.indices.filter { ranges[$0].map(holdsWanted) ?? false })
                try PBFReader(url: url).readInOrder(blobs: chosen, make: { MemberWays(wanted: wanted) }) { part in
                    pieces.merge(part.found) { first, _ in first }
                    part.found.removeAll(keepingCapacity: true)
                }
            }
            for (i, outers) in relationOuters.enumerated() {
                let rings = WaterBodies.closedChains(of: outers.compactMap { pieces[$0] }).filter { $0.count >= 4 }
                guard !rings.isEmpty else { continue }
                let holes = WaterBodies.closedChains(of: relationInners[i].compactMap { pieces[$0] }).filter {
                    $0.count >= 4
                }
                for way in outers { polygonsOf[way, default: []].append(polygonName.count) }
                polygonName.append(relationName[i])
                polygonDescription.append(relationDescription[i])
                polygonRings.append((rings, holes))
            }
        }

        /// Second pass: where the closed ways are. Each is placed inside itself: at its
        /// centroid, or where that falls outside, as for a crescent, a beach or a lake with a
        /// bay, midway along the widest stretch of it on the centroid's latitude.
        func resolve(urls: [URL]) throws -> [Point] {
            guard !areaName.isEmpty || !polygonName.isEmpty else { return points }
            let polygonRefs = polygonRings.flatMap { Array($0.outers.joined()) + Array($0.inners.joined()) }
            let wanted = NodePlaces.wantedIDs(from: areaRefs + polygonRefs)
            let gathered = try urls.map { try NodePlaces.gather(wanted, from: $0) }
            func placeOf(_ id: Int64) -> (lat: Double, lon: Double)? {
                for places in gathered { if let place = places.place(of: id) { return place } }
                return nil
            }

            // A multipolygon by its largest outer ring, its own holes left out: a museum's
            // point is not put in its courtyard.
            var polygonPoints: [Int: Point] = [:]
            for (i, rings) in polygonRings.enumerated() {
                let outers = rings.outers.map { $0.compactMap(placeOf) }
                guard let outer = outers.max(by: { MakeGPI.area($0) < MakeGPI.area($1) }),
                    let inside = MakeGPI.pointInside(outer, holes: rings.inners.map { $0.compactMap(placeOf) })
                else { continue }
                polygonPoints[i] = Point(
                    lat: inside.lat,
                    lon: inside.lon,
                    name: polygonName[i],
                    description: polygonDescription[i]
                )
            }

            var out = points
            for i in 0..<areaName.count {
                // An outer way tagged as its multipolygon is: the polygon's point stands for
                // both, where it has one, and the way's own centroid may be in the courtyard.
                let twin = polygonsOf[areaWay[i]]?.contains {
                    polygonPoints[$0] != nil && polygonName[$0] == areaName[i]
                        && polygonDescription[$0] == areaDescription[i]
                }
                if twin == true { continue }
                let ring = (Int(areaStart[i])..<Int(areaStart[i + 1])).compactMap { placeOf(areaRefs[$0]) }
                guard let inside = MakeGPI.pointInside(ring) else { continue }
                out.append(Point(lat: inside.lat, lon: inside.lon, name: areaName[i], description: areaDescription[i]))
            }
            out += polygonPoints.keys.sorted().compactMap { polygonPoints[$0] }
            return out
        }
    }
}

extension MakeGPI {
    /// Labels for the unnamed, as the Russian map draws them: `key=value` to its word.
    static let russianLabels: [String: String] = {
        var out: [String: String] = [:]
        for raw in StyleAssets.russianLabels.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let bar = line.firstIndex(of: "|") else { continue }
            out[String(line[line.startIndex..<bar])] = String(line[line.index(after: bar)...])
        }
        return out
    }()

    /// What an unnamed thing is called in Russian: as the map labels it, else by the
    /// list below, else as the hide list names it.
    static func russianName(key: String, value: String) -> String? {
        russianLabels["\(key)=\(value)"] ?? russianExtras["\(key)=\(value)"]
            ?? HideableNames.features["\(key)-\(value)"]
    }

    /// The kinds a list of POIs has and neither names, and those the hide list names as a
    /// heading in the plural, where 1 point needs the singular.
    private static let russianExtras: [String: String] = [
        "natural=tree": "Дерево",
        "amenity=parking": "Парковка",
        "amenity=vending_machine": "Торговый автомат",
        "man_made=lighthouse": "Маяк",
        "man_made=survey_point": "Геодезический пункт",
        "man_made=beacon": "Навигационный знак",
        "office=government": "Госучреждение",
        "leisure=slipway": "Спуск для лодок"
    ]

    /// The area a ring encloses, in square degrees, either way round.
    static func area(_ ring: [(lat: Double, lon: Double)]) -> Double {
        guard ring.count >= 3 else { return 0 }
        var twice = 0.0
        for i in 0..<ring.count {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            twice += a.lon * b.lat - b.lon * a.lat
        }
        return abs(twice) / 2
    }

    /// A point inside a ring and outside its holes: its centroid where that is inside,
    /// otherwise the middle of the widest stretch inside along the centroid's latitude;
    /// the bounding box's centre for a ring too small to say.
    static func pointInside(
        _ ring: [(lat: Double, lon: Double)],
        holes: [[(lat: Double, lon: Double)]] = []
    ) -> (lat: Double, lon: Double)? {
        guard !ring.isEmpty else { return nil }
        let lats = ring.map(\.lat), lons = ring.map(\.lon)
        let box = ((lats.min()! + lats.max()!) / 2, (lons.min()! + lons.max()!) / 2)
        guard ring.count >= 4 else { return box }
        var twice = 0.0, cLat = 0.0, cLon = 0.0
        for i in 0..<ring.count {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            let cross = a.lon * b.lat - b.lon * a.lat
            twice += cross
            cLon += (a.lon + b.lon) * cross
            cLat += (a.lat + b.lat) * cross
        }
        guard abs(twice) > 1e-18 else { return box }
        let centroid = (lat: cLat / (3 * twice), lon: cLon / (3 * twice))
        // Even-odd over the ring and its holes alike: each pair of crossings bounds ground.
        var crossings: [Double] = []
        for edges in [ring] + holes {
            for i in 0..<edges.count {
                let a = edges[i], b = edges[(i + 1) % edges.count]
                if (a.lat > centroid.lat) == (b.lat > centroid.lat) { continue }
                crossings.append(a.lon + (b.lon - a.lon) * (centroid.lat - a.lat) / (b.lat - a.lat))
            }
        }
        crossings.sort()
        var widest: (from: Double, to: Double)?
        var at = 0
        while at + 1 < crossings.count {
            if crossings[at] <= centroid.lon && centroid.lon <= crossings[at + 1] { return centroid }
            if crossings[at + 1] - crossings[at] > (widest.map { $0.to - $0.from } ?? -1) {
                widest = (crossings[at], crossings[at + 1])
            }
            at += 2
        }
        guard let widest else { return box }
        return (centroid.lat, (widest.from + widest.to) / 2)
    }
}
