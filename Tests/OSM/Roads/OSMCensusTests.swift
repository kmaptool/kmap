import XCTest
@testable import kmap

/// Counting what a repair pass will have to hold.
///
/// The census walks the loader's classification ladder and reports the tag's own word, so
/// its counts can be compared against an independent reader of the same file.
final class OSMCensusTests: XCTestCase {

    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-census-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func census(nodes: Int,
                        ways: [(id: Int64, refs: [Int64], tags: [(String, String)])])
    throws -> OSMCensus {
        let url = directory.appendingPathComponent("in.osm.pbf")
        let writer = try PBFWriter(to: url)
        writer.header()
        if nodes > 0 {
            writer.nodes((1...nodes).map {
                PBFWriter.Node(id: Int64($0), lat: 44.5, lon: 33.5, tags: [])
            })
        }
        if !ways.isEmpty {
            writer.ways(ways.map { PBFWriter.Way(id: $0.id, refs: $0.refs, tags: $0.tags) })
        }
        try writer.finish()
        var counted = OSMCensus()
        try PBFReader(url: url).read(into: &counted)
        return counted
    }

    // MARK: Counting

    func testEveryNodeAndWayIsCounted() throws {
        let counted = try census(nodes: 5, ways: [
            (10, [1, 2, 3], [("highway", "track")]),
            (11, [3, 4], [("barrier", "fence")]),
            (12, [4, 5], [("landuse", "meadow")]),
        ])
        XCTAssertEqual(counted.nodes, 5)
        XCTAssertEqual(counted.ways, 3)
    }

    func testObjectsCarryingHouseNumbersAreCounted() throws {
        // What mkgmap's address search is built from; the census proves the data went in.
        let counted = try census(nodes: 2, ways: [
            (10, [1, 2], [("building", "yes"), ("addr:housenumber", "17")]),
            (11, [1, 2], [("highway", "residential")]),
        ])
        XCTAssertEqual(counted.addresses, 1)
    }

    func testRoadsAreCountedWithTheirPointsAndNothingElseIs() throws {
        let counted = try census(nodes: 6, ways: [
            (10, [1, 2, 3], [("highway", "residential")]),
            (11, [3, 4, 5, 6], [("highway", "path")]),
            (12, [1, 6], [("highway", "proposed")]),      // not a way anything routes on
        ])
        XCTAssertEqual(counted.roads, 2)
        XCTAssertEqual(counted.roadPoints, 3 + 4)
        XCTAssertEqual(counted.obstacles, 0)
    }

    func testAWayIsCountedAsARoadOrAnObstacleAndNeverAsBoth() throws {
        // A way tagged both ways counts as a road; counting it twice would inflate the
        // totals.
        let counted = try census(nodes: 3, ways: [
            (10, [1, 2, 3], [("highway", "track"), ("barrier", "fence")]),
        ])
        XCTAssertEqual(counted.roads, 1)
        XCTAssertEqual(counted.roadPoints, 3)
        XCTAssertEqual(counted.obstacles, 0)
        XCTAssertEqual(counted.obstaclePoints, 0)
    }

    func testObstaclesAreCountedWithTheirPoints() throws {
        let counted = try census(nodes: 8, ways: [
            (10, [1, 2], [("barrier", "fence")]),
            (11, [3, 4, 5], [("building", "yes")]),
            (12, [6, 7, 8], [("natural", "cliff")]),
            (13, [1, 8], [("landuse", "meadow")]),        // neither road nor obstacle
        ])
        XCTAssertEqual(counted.obstacles, 3)
        XCTAssertEqual(counted.obstaclePoints, 2 + 3 + 3)
        XCTAssertEqual(counted.roads, 0)
    }

    func testAnEmptyExtractCountsNothingRatherThanFailing() throws {
        let counted = try census(nodes: 0, ways: [])
        XCTAssertEqual(counted.nodes, 0)
        XCTAssertEqual(counted.ways, 0)
        XCTAssertEqual(counted.roads, 0)
    }

    // MARK: The ladder

    func testAnObstacleIsNamedInThePythonToolsWords() {
        // The census reports the tag's own word where the loader reports its class.
        XCTAssertEqual(OSMCensus.obstacleKind(barrier: "kerb", natural: nil, waterway: nil,
                                              manMade: nil, building: false), "kerb")
        XCTAssertEqual(OSMCensus.obstacleKind(barrier: "fence", natural: nil, waterway: nil,
                                              manMade: nil, building: false), "fence")
        XCTAssertEqual(OSMCensus.obstacleKind(barrier: nil, natural: "cliff", waterway: nil,
                                              manMade: nil, building: false), "cliff")
        XCTAssertEqual(OSMCensus.obstacleKind(barrier: nil, natural: nil, waterway: "river",
                                              manMade: nil, building: false), "water")
        XCTAssertEqual(OSMCensus.obstacleKind(barrier: nil, natural: nil, waterway: nil,
                                              manMade: nil, building: true), "building")
    }

    func testSomethingInTheWayOfNothingIsNotAnObstacle() {
        XCTAssertNil(OSMCensus.obstacleKind(barrier: nil, natural: nil, waterway: nil,
                                            manMade: nil, building: false))
        XCTAssertNil(OSMCensus.obstacleKind(barrier: nil, natural: "wood", waterway: nil,
                                            manMade: nil, building: false))
        // Only a river or a canal counts as water; a stream or a ditch is crossable.
        XCTAssertNil(OSMCensus.obstacleKind(barrier: nil, natural: nil, waterway: "stream",
                                            manMade: nil, building: false))
        XCTAssertNil(OSMCensus.obstacleKind(barrier: nil, natural: nil, waterway: "ditch",
                                            manMade: nil, building: false))
    }

    func testTheCensusAndTheLoaderWalkOneLadderAndNotTwo() {
        // Every combination either counts here and loads there, or in neither.
        let barriers = [nil, "fence", "wall", "hedge", "gate", "kerb", "bollard"]
        let naturals = [nil, "cliff", "wood", "water"]
        let waterways = [nil, "stream", "riverbank"]
        let manMades = [nil, "embankment", "pier"]
        for barrier in barriers {
            for natural in naturals {
                for waterway in waterways {
                    for manMade in manMades {
                        for building in [false, true] {
                            let counted = OSMCensus.obstacleKind(
                                barrier: barrier, natural: natural, waterway: waterway,
                                manMade: manMade, building: building)
                            let loaded = RoadNetworkLoader.obstacleKind(
                                barrier: barrier, natural: natural, waterway: waterway,
                                manMade: manMade, building: building)
                            XCTAssertEqual(counted == nil, loaded == nil,
                                           "\(barrier ?? "-") \(natural ?? "-")"
                                           + " \(waterway ?? "-") \(manMade ?? "-") \(building)")
                        }
                    }
                }
            }
        }
    }

    func testTheRoadListIsTheOneTheRepairRoutesOn() {
        for kind in ["motorway", "trunk", "primary", "secondary", "tertiary", "unclassified",
                     "residential", "service", "track", "path", "footway", "cycleway",
                     "bridleway", "living_street", "road", "steps", "pedestrian"] {
            XCTAssertTrue(OSMCensus.roadKinds.contains(kind), kind)
        }
        // Link roads count as roads, or a junction becomes a hole in the network.
        for kind in ["motorway_link", "trunk_link", "primary_link", "secondary_link",
                     "tertiary_link"] {
            XCTAssertTrue(OSMCensus.roadKinds.contains(kind), kind)
        }
        for kind in ["proposed", "raceway", "bus_guideway", "elevator"] {
            XCTAssertFalse(OSMCensus.roadKinds.contains(kind), kind)
        }
    }
}
