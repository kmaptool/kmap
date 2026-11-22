import Foundation

extension RegionSuggestion {
    /// Where a map draws: a box per subdivision of the finest level, weighed by its bytes
    /// of RGN, so ground a tile's rectangle merely spans weighs nothing.
    ///
    /// `tiles` is the ground the map covers. Both lie within -180...180, a box across
    /// 180 deg as its 2 sides.
    struct DrawnGround {
        let spots: [Spot]
        let tiles: [BBox]

        init(spots: [Spot], tiles: [BBox]) {
            self.spots = spots.flatMap { spot -> [Spot] in
                let sides = spot.box.sidesOf180
                guard sides.count > 1 else { return [Spot(box: sides[0], weight: spot.weight)] }
                let width = spot.box.maxLon - spot.box.minLon
                return sides.map { Spot(box: $0, weight: spot.weight * ($0.maxLon - $0.minLon) / width) }
            }
            self.tiles = tiles.flatMap(\.sidesOf180)
        }
    }

    /// The rectangle around a map's tiles, from their headers alone. Where the tiles lie
    /// either side of 180 deg it runs across, its east edge past 180.
    static func frame(of img: URL) -> BBox {
        frame(
            around: MapCoverage.tiles(in: img).map {
                BBox(minLon: $0.minLon, minLat: $0.minLat, maxLon: $0.maxLon, maxLat: $0.maxLat)
            }
        )
    }

    static func frame(around tiles: [BBox]) -> BBox {
        let sides = tiles.flatMap(\.sidesOf180).filter(\.isValid)
        var frame = BBox.empty
        for side in sides {
            frame.extend(lon: side.minLon, lat: side.minLat)
            frame.extend(lon: side.maxLon, lat: side.maxLat)
        }
        // The widest gap between the tiles lying inside the frame: the map is the rest
        // of the circle, through 180 deg.
        if let gap = LongitudeCircle.gapInside(sides.map { ($0.minLon, $0.maxLon) }) {
            frame.minLon = gap.east
            frame.maxLon = gap.west + 360
        }
        return frame
    }

    static func drawnGround(of img: URL) -> DrawnGround {
        let directory = ImgContainer.directory(of: img)
        let sizes = Dictionary(
            directory.filter { $0.ext.uppercased() == "RGN" }.map { ($0.name, Double($0.size)) },
            uniquingKeysWith: max
        )
        let trees = Dictionary(
            directory.filter { $0.ext.uppercased() == "TRE" }.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let tiles = MapCoverage.tiles(in: img)
        let boxes = tiles.map { BBox(minLon: $0.minLon, minLat: $0.minLat, maxLon: $0.maxLon, maxLat: $0.maxLat) }
        // A tile showing no data at the detail level is 1 box weighed by its RGN's size.
        var spots = Lanes.map(tiles.count) { at -> [DrawnGround.Spot] in
            let detail = trees[tiles[at].name].map { self.detail(of: $0, in: img, within: boxes[at]) } ?? []
            return detail.isEmpty ? [DrawnGround.Spot(box: boxes[at], weight: sizes[tiles[at].name] ?? 0)] : detail
        }.flatMap { $0 }
        // Nothing weighs anything: by area instead, wrong for border tiles and never
        // all zeros.
        if spots.allSatisfy({ $0.weight <= 0 }) {
            spots = spots.map { DrawnGround.Spot(box: $0.box, weight: max($0.box.squareDegrees, 1e-9)) }
        }
        return DrawnGround(spots: spots, tiles: boxes)
    }

    /// The finest subdivisions of a tile that hold data, each cut to the tile's box. One
    /// stating ground outside its tile is weighed over the tile.
    private static func detail(of tre: ImgContainer.SubFile, in img: URL, within tile: BBox) -> [DrawnGround.Spot] {
        guard let data = ImgContainer.read(tre, from: img), let tree = try? ImgElements.Tree(data, tile: tre.name)
        else { return [] }
        let middle = (tile.minLon + tile.maxLon) / 2
        return tree.subdivisions.compactMap { division -> DrawnGround.Spot? in
            guard division.level == 0, division.dataBytes > 0 else { return nil }
            var box = division.box
            // A tile across 180 deg states its east edge past 180; its subdivisions do not.
            let turn = ((middle - (box.minLon + box.maxLon) / 2) / 360).rounded() * 360
            box.minLon += turn
            box.maxLon += turn
            let cut = BBox(
                minLon: max(box.minLon, tile.minLon),
                minLat: max(box.minLat, tile.minLat),
                maxLon: min(box.maxLon, tile.maxLon),
                maxLat: min(box.maxLat, tile.maxLat)
            )
            return DrawnGround.Spot(box: cut.isValid ? cut : tile, weight: Double(division.dataBytes))
        }
    }
}
