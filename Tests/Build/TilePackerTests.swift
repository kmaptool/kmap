import XCTest
@testable import kmap

/// Which compiled tiles go into which output file: arithmetic over tile weights and
/// bounding boxes.
final class TilePackerTests: XCTestCase {

    private func tile(_ id: String, _ bytes: Int64,
                      lat: Double = 44, lon: Double = 33) -> TilePacker.Tile {
        TilePacker.Tile(id: id, bbox: BBox(minLon: lon, minLat: lat,
                                           maxLon: lon + 0.1, maxLat: lat + 0.1),
                        bytes: bytes)
    }

    private func packer(_ mode: SplitMode, axis: SplitAxis = .longitude,
                        regions: [Region] = [], countryOf: [String: String] = [:])
        -> TilePacker {
        TilePacker(mode: mode, axis: axis, slug: "map", regions: regions,
                   countryOf: countryOf)
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
        let tiles = (1...20).map { tile("tile\($0)", Int64($0) * 100_000_000,
                                        lon: 33 + Double($0)) }
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
        let tiles = [tile("d", 1, lon: 36), tile("b", 1, lon: 34),
                     tile("a", 1, lon: 33), tile("c", 1, lon: 35)]
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
        XCTAssertEqual(packer(.perRegion, regions: regions)
            .groups(tiles, upTo: 4_000_000_000).map(\.name), ["here"])
    }

    func testRegionsOfOneCountryShareAFile() {
        let regions = [region("child-a", lat: 48, lon: 11), region("child-b", lat: 50, lon: 9)]
        let tiles = [tile("a", 1, lat: 48.2, lon: 11.2), tile("b", 1, lat: 50.2, lon: 9.2)]
        let groups = packer(.perCountry, regions: regions,
                            countryOf: ["child-a": "parent-region", "child-b": "parent-region"])
            .groups(tiles, upTo: 4_000_000_000)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].name, "parent-region")
        XCTAssertEqual(groups[0].members.count, 2)
    }

    func testARegionTooBigForACardIsStillCut() {
        // The choice was which ground goes together, not how big a file may be.
        let regions = [region("here", lat: 44, lon: 33)]
        let tiles = (1...6).map { tile("tile\($0)", 1_000_000_000, lat: 44.1,
                                       lon: 33 + Double($0) * 0.1) }
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
