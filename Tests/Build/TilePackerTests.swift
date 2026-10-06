import XCTest

@testable import kmap

/// Which compiled tiles go into which output file: arithmetic over tile weights and
/// bounding boxes.
final class TilePackerTests: XCTestCase {
    private func tile(
        _ id: String,
        _ bytes: Int64,
        lat: Double = 44,
        lon: Double = 33
    ) -> TilePacker.Tile {
        TilePacker.Tile(
            id: id,
            bbox: BBox(
                minLon: lon,
                minLat: lat,
                maxLon: lon + 0.1,
                maxLat: lat + 0.1
            ),
            bytes: bytes
        )
    }

    private func packer(
        _ mode: SplitMode,
        axis: SplitAxis = .longitude,
        regions: [Region] = [],
        countryOf: [String: String] = [:]
    ) -> TilePacker {
        TilePacker(
            mode: mode,
            axis: axis,
            slug: "map",
            regions: regions,
            countryOf: countryOf
        )
    }

    // MARK: Fitting a card

    func testEverythingInOneFileWhenItFits() {
        let tiles = (1...4).map { tile("tile\($0)", 10_000_000, lon: 33 + Double($0)) }
        let groups = packer(.fitCard).groups(tiles, upTo: 4_000_000_000)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].name, "map")
        XCTAssertEqual(groups[0].members.count, 4)
    }

    func testCutIntoAsFewFilesAsTheLimitAllows() {
        // Ten tiles of a gigabyte against a four-gigabyte limit: three files.
        let tiles = (1...10).map { tile("tile\($0)", 1_000_000_000, lon: 33 + Double($0)) }
        let groups = packer(.fitCard).groups(tiles, upTo: 4_000_000_000)
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups.map(\.members.count), [4, 4, 2])
    }

    func testNoFileIsOverTheLimit() {
        let tiles = (1...20).map {
            tile(
                "tile\($0)",
                Int64($0) * 100_000_000,
                lon: 33 + Double($0)
            )
        }
        let groups = packer(.fitCard).groups(tiles, upTo: 1_000_000_000)
        for group in groups where group.members.count > 1 {
            let bytes = group.members.reduce(Int64(0)) { $0 + tiles[$1].bytes }
            XCTAssertLessThanOrEqual(bytes, 1_000_000_000)
        }
    }

    func testEveryTileLandsInExactlyOneFile() {
        let tiles = (1...17).map { tile("tile\($0)", 300_000_000, lon: 33 + Double($0)) }
        let groups = packer(.fitCard).groups(tiles, upTo: 1_000_000_000)
        XCTAssertEqual(groups.flatMap(\.members).sorted(), Array(0..<17))
    }

    func testTwoFilesAreNamedForTheirHalvesOfTheMap() {
        let tiles = (1...4).map { tile("tile\($0)", 1_000_000_000, lon: 33 + Double($0)) }
        let east = packer(.fitCard, axis: .longitude).groups(tiles, upTo: 2_000_000_000)
        XCTAssertEqual(east.map(\.name), ["map-west", "map-east"])
        let north = packer(.fitCard, axis: .latitude).groups(tiles, upTo: 2_000_000_000)
        XCTAssertEqual(north.map(\.name), ["map-south", "map-north"])
    }

    func testMoreThanTwoFilesAreNumbered() {
        let tiles = (1...6).map { tile("tile\($0)", 1_000_000_000, lon: 33 + Double($0)) }
        let groups = packer(.fitCard).groups(tiles, upTo: 2_000_000_000)
        XCTAssertEqual(groups.map(\.name), ["map-part1", "map-part2", "map-part3"])
    }

    func testFilesFollowTheGroundFromWestToEast() {
        // Handed over in a jumble; the first file must still hold the western tiles.
        let tiles = [
            tile("d", 1, lon: 36), tile("b", 1, lon: 34),
            tile("a", 1, lon: 33), tile("c", 1, lon: 35)
        ]
        let groups = packer(.count(2)).groups(tiles, upTo: 4_000_000_000)
        XCTAssertEqual(groups[0].members.map { tiles[$0].id }, ["a", "b"])
        XCTAssertEqual(groups[1].members.map { tiles[$0].id }, ["c", "d"])
    }

    // MARK: A number the user chose

    func testAskingForThreeFilesGivesThree() {
        let tiles = (1...9).map { tile("tile\($0)", 100_000_000, lon: 33 + Double($0)) }
        let groups = packer(.count(3)).groups(tiles, upTo: 4_000_000_000)
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups.map(\.members.count), [3, 3, 3])
    }

    /// A heavy file early on must not swallow the shares of those after it.
    func testTheCountAskedForIsTheCountWrittenWhateverTheWeights() {
        for (weights, wanted) in [
            ([10, 1, 1, 1], 3), ([5, 5, 5, 5, 1], 4), ([3, 3, 3, 3, 3, 1, 1], 5), ([1, 1, 1, 1, 1, 1, 1, 9], 4)
        ] {
            let tiles = weights.enumerated().map {
                tile("t\($0.offset)", Int64($0.element) * 1_000_000, lon: 33 + Double($0.offset))
            }
            let groups = packer(.count(wanted)).groups(tiles, upTo: 4_000_000_000)
            XCTAssertEqual(groups.count, wanted, "\(weights)")
            XCTAssertEqual(groups.flatMap(\.members).sorted(), Array(tiles.indices), "\(weights)")
        }
    }

    func testAskingForMoreFilesThanThereAreTilesGivesOnePerTile() {
        let tiles = (1...2).map { tile("tile\($0)", 100, lon: 33 + Double($0)) }
        XCTAssertEqual(packer(.count(8)).groups(tiles, upTo: 4_000_000_000).count, 2)
    }

    func testTheFilesAreOfRoughlyEqualWeightNotEqualCount() {
        // One heavy tile and four light ones: the heavy one is a file on its own.
        var tiles = [tile("heavy", 1_000_000_000, lon: 33)]
        for i in 1...4 { tiles.append(tile("light\(i)", 1_000_000, lon: 33 + Double(i))) }
        let groups = packer(.count(2)).groups(tiles, upTo: 4_000_000_000)
        XCTAssertEqual(groups[0].members.map { tiles[$0].id }, ["heavy"])
        XCTAssertEqual(groups[1].members.count, 4)
    }

    // MARK: By region and by country

    private func region(_ id: String, lat: Double, lon: Double) -> Region {
        let box = BBox(minLon: lon, minLat: lat, maxLon: lon + 1, maxLat: lat + 1)
        return Region(id: id, name: id, parentID: nil, pbfURL: nil, bbox: box, boxes: [box])
    }

    func testATileGoesWithTheRegionThatHoldsIt() {
        let regions = [region("here", lat: 44, lon: 33), region("there", lat: 50, lon: 6)]
        let tiles = [tile("a", 1, lat: 44.2, lon: 33.2), tile("b", 1, lat: 50.2, lon: 6.2)]
        let groups = packer(.perRegion, regions: regions).groups(tiles, upTo: 4_000_000_000)
        XCTAssertEqual(Set(groups.map(\.name)), ["here", "there"])
        XCTAssertTrue(groups.allSatisfy { $0.members.count == 1 })
    }

    func testATileBetweenTwoRegionsGoesWithTheNearest() {
        let regions = [region("here", lat: 44, lon: 33), region("there", lat: 50, lon: 6)]
        let tiles = [tile("stray", 1, lat: 45.5, lon: 34.5)]
        XCTAssertEqual(
            packer(.perRegion, regions: regions)
                .groups(tiles, upTo: 4_000_000_000).map(\.name),
            ["here"]
        )
    }

    /// A joined map is cut over the rectangle around both regions, so a tile may span the
    /// empty ground between them: it goes with the region whose ground it holds, however
    /// near its centre falls to the other.
    func testATileSpanningTheGapGoesWithTheRegionItOverlaps() {
        func box(_ minLat: Double, _ maxLat: Double, _ minLon: Double, _ maxLon: Double) -> BBox {
            BBox(minLon: minLon, minLat: minLat, maxLon: maxLon, maxLat: maxLat)
        }
        let andorra = box(42.42, 42.66, 1.41, 1.79)
        let monaco = box(43.72, 43.75, 7.40, 7.44)
        let regions = [
            Region(id: "andorra", name: "Andorra", parentID: nil, pbfURL: nil, bbox: andorra, boxes: [andorra]),
            Region(id: "monaco", name: "Monaco", parentID: nil, pbfURL: nil, bbox: monaco, boxes: [monaco])
        ]
        let tiles = [
            TilePacker.Tile(id: "south", bbox: box(42.30, 43.07, 1.41, 7.60), bytes: 1),
            TilePacker.Tile(id: "north", bbox: box(43.07, 43.77, 1.41, 7.60), bytes: 1)
        ]
        let groups = packer(.perRegion, regions: regions).groups(tiles, upTo: 4_000_000_000)
        XCTAssertEqual(groups.map(\.name).sorted(), ["andorra", "monaco"])
        XCTAssertEqual(groups.first { $0.name == "monaco" }?.members, [1])
    }

    /// A small region inside a neighbour's box keeps its own tiles: Andorra within Spain's
    /// rectangle. Its outline holds the tile's centre and Spain's does not.
    func testASmallRegionInsideItsNeighboursBoxKeepsItsTiles() {
        let spainBox = BBox(minLon: -9.3, minLat: 36, maxLon: 3.3, maxLat: 43.8)
        let andorraBox = BBox(minLon: 1.41, minLat: 42.42, maxLon: 1.79, maxLat: 42.66)
        // Spain's outline leaves a notch where Andorra is.
        var spain = Region(id: "spain", name: "Spain", parentID: nil, pbfURL: nil, bbox: spainBox, boxes: [spainBox])
        spain.rings = [
            [
                (lon: -9.3, lat: 36), (lon: 3.3, lat: 36), (lon: 3.3, lat: 42.4), (lon: 1.4, lat: 42.4),
                (lon: 1.4, lat: 42.7), (lon: 3.3, lat: 42.7), (lon: 3.3, lat: 43.8), (lon: -9.3, lat: 43.8)
            ]
        ]
        XCTAssertFalse(spain.holds(lat: 42.55, lon: 1.6), "the notch is Andorra's")
        XCTAssertTrue(spain.holds(lat: 40, lon: -3))
        let andorra = Region(
            id: "andorra",
            name: "Andorra",
            parentID: nil,
            pbfURL: nil,
            bbox: andorraBox,
            boxes: [andorraBox]
        )
        let tiles = [
            TilePacker.Tile(id: "pyrenees", bbox: BBox(minLon: 1.3, minLat: 42.3, maxLon: 1.9, maxLat: 42.8), bytes: 1)
        ]
        for regions in [[spain, andorra], [andorra, spain]] {
            XCTAssertEqual(
                packer(.perRegion, regions: regions).groups(tiles, upTo: 4_000_000_000).map(\.name),
                ["andorra"]
            )
        }
    }

    func testRegionsOfOneCountryShareAFile() {
        let regions = [region("child-a", lat: 48, lon: 11), region("child-b", lat: 50, lon: 9)]
        let tiles = [tile("a", 1, lat: 48.2, lon: 11.2), tile("b", 1, lat: 50.2, lon: 9.2)]
        let groups = packer(
            .perCountry,
            regions: regions,
            countryOf: ["child-a": "parent-region", "child-b": "parent-region"]
        )
        .groups(tiles, upTo: 4_000_000_000)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].name, "parent-region")
        XCTAssertEqual(groups[0].members.count, 2)
    }

    func testARegionTooBigForACardIsStillCut() {
        // The choice was which ground goes together, not how big a file may be.
        let regions = [region("here", lat: 44, lon: 33)]
        let tiles = (1...6).map {
            tile(
                "tile\($0)",
                1_000_000_000,
                lat: 44.1,
                lon: 33 + Double($0) * 0.1
            )
        }
        let groups = packer(.perRegion, regions: regions).groups(tiles, upTo: 2_000_000_000)
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups.map(\.name), ["here-part1", "here-part2", "here-part3"])
    }

    // MARK: Nothing at all

    func testNoTilesGiveNoFiles() {
        XCTAssertTrue(packer(.fitCard).groups([], upTo: 1_000).isEmpty)
        XCTAssertTrue(packer(.count(3)).groups([], upTo: 1_000).isEmpty)
        XCTAssertTrue(packer(.perRegion).groups([], upTo: 1_000).isEmpty)
    }
}
