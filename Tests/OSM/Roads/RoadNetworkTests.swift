import XCTest
@testable import kmap

/// Reading an extract into the flat arrays the repair pass works on.
///
/// Classification carries most of the weight: a fence and a kerb are both `barrier=*` in
/// OSM and mean opposite things to a router.
final class RoadNetworkTests: XCTestCase {

    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-network-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func path(_ name: String) -> URL { directory.appendingPathComponent(name) }

    // MARK: Which deck a way is on

    func testLevelFoldsLayerBridgeAndTunnelIntoOneNumber() {
        // Two ends meet only if the level matches, so each tag must move the number.
        let ground = RoadNetworkLoader.level(layer: "0", bridge: "no", tunnel: "no")
        XCTAssertEqual(ground, 0)
        XCTAssertNotEqual(RoadNetworkLoader.level(layer: "1", bridge: "no", tunnel: "no"), ground)
        XCTAssertNotEqual(RoadNetworkLoader.level(layer: "0", bridge: "yes", tunnel: "no"), ground)
        XCTAssertNotEqual(RoadNetworkLoader.level(layer: "0", bridge: "no", tunnel: "yes"), ground)
        XCTAssertNotEqual(RoadNetworkLoader.level(layer: "-1", bridge: "no", tunnel: "no"), ground)
        XCTAssertNotEqual(RoadNetworkLoader.level(layer: "1", bridge: "yes", tunnel: "no"),
                          RoadNetworkLoader.level(layer: "1", bridge: "no", tunnel: "yes"))
    }

    func testANonsenseLayerReadsAsTheGround() {
        // A layer value that is not a number falls back to the ground.
        XCTAssertEqual(RoadNetworkLoader.level(layer: "ground floor", bridge: "no", tunnel: "no"),
                       RoadNetworkLoader.level(layer: "0", bridge: "no", tunnel: "no"))
        XCTAssertEqual(RoadNetworkLoader.level(layer: "", bridge: "no", tunnel: "no"),
                       RoadNetworkLoader.level(layer: "0", bridge: "no", tunnel: "no"))
    }

    // MARK: What counts as an obstacle

    private func kind(barrier: String? = nil, natural: String? = nil, waterway: String? = nil,
                      manMade: String? = nil, building: Bool = false) -> ObstacleKind? {
        RoadNetworkLoader.obstacleKind(barrier: barrier, natural: natural, waterway: waterway,
                                       manMade: manMade, building: building)
    }

    func testAPlotBoundaryIsAFenceAndACrossableOneIsNot() {
        // A fence is impassable; a crossable barrier is not.
        XCTAssertEqual(kind(barrier: "fence"), .fence)
        XCTAssertEqual(kind(barrier: "wall"), .fence)
        XCTAssertEqual(kind(barrier: "hedge"), .fence)
        XCTAssertEqual(kind(barrier: "kerb"), .barrier)
        XCTAssertEqual(kind(barrier: "guard_rail"), .barrier)
        XCTAssertEqual(kind(barrier: "chain"), .barrier)
    }

    func testAnUnknownBarrierIsStillABarrier() {
        // An unlisted barrier value is crossable rather than ignored.
        XCTAssertEqual(kind(barrier: "something_new_in_2027"), .barrier)
    }

    func testTheNaturalWorldIsSortedByWhatItDoesToARoute() {
        XCTAssertEqual(kind(natural: "cliff"), .cliff)
        XCTAssertEqual(kind(natural: "arete"), .cliff)
        XCTAssertEqual(kind(natural: "gully"), .ravine)
        XCTAssertEqual(kind(natural: "gorge"), .ravine)
        XCTAssertEqual(kind(natural: "sinkhole"), .ravine)
        XCTAssertEqual(kind(waterway: "river"), .water)
        XCTAssertEqual(kind(waterway: "canal"), .water)
        // A stream is crossable and so is not an obstacle.
        XCTAssertNil(kind(waterway: "stream"))
        XCTAssertNil(kind(waterway: "ditch"))
        XCTAssertEqual(kind(manMade: "embankment"), .embankment)
        XCTAssertEqual(kind(manMade: "pier"), .embankment)
        XCTAssertEqual(kind(manMade: "breakwater"), .embankment)
        XCTAssertNil(kind(manMade: "surveillance"))
    }

    func testABuildingIsAnObstacleAndAnUntaggedWayIsNot() {
        XCTAssertEqual(kind(building: true), .building)
        XCTAssertNil(kind())
    }

    func testABarrierTagWinsOverEverythingElseOnTheSameWay() {
        // `barrier` is tested first, then `natural`, then `building`.
        XCTAssertEqual(kind(barrier: "fence", natural: "cliff"), .fence)
        XCTAssertEqual(kind(barrier: "kerb", building: true), .barrier)
        XCTAssertEqual(kind(natural: "cliff", building: true), .cliff)
    }

    func testOnlyAFenceOrABuildingIsImpassable() {
        XCTAssertTrue(ObstacleKind.fence.isImpassable)
        XCTAssertTrue(ObstacleKind.building.isImpassable)
        for kind in [ObstacleKind.cliff, .ravine, .water, .embankment, .barrier] {
            XCTAssertFalse(kind.isImpassable, "\(kind)")
        }
    }

    // MARK: Reading a file

    /// Writes an extract holding the given ways, with the nodes laid out along a line.
    private func extract(_ name: String, ways: [(id: Int64, refs: [Int64],
                                                 tags: [(String, String)])],
                         nodes: [Int64]) throws -> URL {
        let url = path(name)
        let writer = try PBFWriter(to: url)
        writer.header()
        writer.nodes(nodes.map {
            PBFWriter.Node(id: $0, lat: 44.5 + Double($0) * 1e-4, lon: 33.5, tags: [])
        })
        writer.ways(ways.map { PBFWriter.Way(id: $0.id, refs: $0.refs, tags: $0.tags) })
        try writer.finish()
        return url
    }

    func testARoadComesBackWithItsPointsInOrder() throws {
        let url = try extract("road.osm.pbf",
                              ways: [(1, [10, 11, 12], [("highway", "track")])],
                              nodes: [10, 11, 12])
        let network = try RoadNetworkLoader(url: url).load()
        XCTAssertEqual(network.wayCount, 1)
        XCTAssertEqual(network.wayID, [1])
        XCTAssertEqual(Array(network.points(of: 0)), [0, 1, 2])
        XCTAssertEqual(network.refs, [10, 11, 12])
        XCTAssertLessThan(network.lat[0], network.lat[1])
    }

    func testAWayNamingNodesTheExtractDoesNotHoldKeepsTheRest() throws {
        // An extract is cut out of a larger one, and the cut runs through ways.
        let url = try extract("cut.osm.pbf",
                              ways: [(1, [10, 999, 11, 12], [("highway", "path")])],
                              nodes: [10, 11, 12])
        let network = try RoadNetworkLoader(url: url).load()
        XCTAssertEqual(network.wayCount, 1)
        XCTAssertEqual(network.refs, [10, 11, 12])
    }

    func testAWayLeftWithOneNodeIsDroppedEntirely() throws {
        // A way left with one node is dropped rather than filled in from whatever the
        // node lookup landed on.
        let url = try extract("stub.osm.pbf",
                              ways: [(1, [10, 998, 999], [("highway", "path")]),
                                     (2, [10, 11], [("highway", "path")])],
                              nodes: [10, 11])
        let network = try RoadNetworkLoader(url: url).load()
        XCTAssertEqual(network.wayID, [2])
        XCTAssertEqual(network.refs, [10, 11])
    }

    func testAWayThatIsNeitherRoadNorObstacleIsIgnored() throws {
        let url = try extract("landuse.osm.pbf",
                              ways: [(1, [10, 11], [("landuse", "meadow")])],
                              nodes: [10, 11])
        let network = try RoadNetworkLoader(url: url).load()
        XCTAssertEqual(network.wayCount, 0)
        XCTAssertEqual(network.obstacleCount, 0)
    }

    func testObstaclesComeBackWithTheirKindWordAndHeight() throws {
        let url = try extract("obstacles.osm.pbf",
                              ways: [(1, [10, 11], [("barrier", "fence"), ("height", "1.8")]),
                                     (2, [11, 12], [("natural", "cliff")])],
                              nodes: [10, 11, 12])
        let network = try RoadNetworkLoader(url: url).load()
        XCTAssertEqual(network.obstacleCount, 2)
        XCTAssertEqual(network.obstacleKind[0], ObstacleKind.fence.rawValue)
        XCTAssertEqual(network.obstacleKind[1], ObstacleKind.cliff.rawValue)
        XCTAssertEqual(network.vocabulary[Int(network.obstacleWord[0])], "fence")
        XCTAssertEqual(network.vocabulary[Int(network.obstacleWord[1])], "cliff")
        XCTAssertEqual(network.obstacleHeight[0], 1.8, accuracy: 0.001)
        XCTAssertTrue(network.obstacleHeight[1].isNaN)
    }

    func testHeightsAreReadHoweverOSMSpellsThem() throws {
        let spellings = [("2", Float(2)), ("2.5", 2.5), ("2,5", 2.5), ("3 m", 3)]
        for (index, spelling) in spellings.enumerated() {
            let url = try extract("height\(index).osm.pbf",
                                  ways: [(1, [10, 11],
                                          [("barrier", "wall"), ("height", spelling.0)])],
                                  nodes: [10, 11])
            let network = try RoadNetworkLoader(url: url).load()
            XCTAssertEqual(network.obstacleHeight[0], spelling.1, accuracy: 0.001, spelling.0)
        }
    }

    func testAHeightThatIsNotANumberIsNoHeight() throws {
        let url = try extract("badheight.osm.pbf",
                              ways: [(1, [10, 11], [("barrier", "wall"), ("height", "tall")])],
                              nodes: [10, 11])
        let network = try RoadNetworkLoader(url: url).load()
        XCTAssertTrue(network.obstacleHeight[0].isNaN)
    }

    func testTheVocabularyIsInternedNotRepeated() throws {
        let url = try extract("words.osm.pbf",
                              ways: [(1, [10, 11], [("barrier", "fence")]),
                                     (2, [11, 12], [("barrier", "fence")]),
                                     (3, [10, 12], [("barrier", "wall")])],
                              nodes: [10, 11, 12])
        let network = try RoadNetworkLoader(url: url).load()
        XCTAssertEqual(network.obstacleCount, 3)
        XCTAssertEqual(network.obstacleWord[0], network.obstacleWord[1])
        XCTAssertNotEqual(network.obstacleWord[0], network.obstacleWord[2])
        XCTAssertEqual(Set(network.vocabulary), ["fence", "wall"])
    }

    func testWhichObstacleAPointBelongsTo() throws {
        let url = try extract("owning.osm.pbf",
                              ways: [(1, [10, 11, 12], [("barrier", "fence")]),
                                     (2, [12, 13], [("barrier", "wall")])],
                              nodes: [10, 11, 12, 13])
        let network = try RoadNetworkLoader(url: url).load()
        XCTAssertEqual(network.obstacleOwning(point: 0), 0)
        XCTAssertEqual(network.obstacleOwning(point: 2), 0)
        XCTAssertEqual(network.obstacleOwning(point: 3), 1)
        XCTAssertEqual(network.obstacleOwning(point: 4), 1)
    }

    func testAWayOfOnePointIsNotAWay() throws {
        let url = try extract("point.osm.pbf",
                              ways: [(1, [10], [("highway", "path")])],
                              nodes: [10])
        let network = try RoadNetworkLoader(url: url).load()
        XCTAssertEqual(network.wayCount, 0)
    }

    func testManyWaysAndNodesAllArriveWithTheRightPlaces() throws {
        // More ways than the reader's internal batch, with the ids interleaved so a
        // lookup walking in step with the file has to keep up.
        var ways: [(id: Int64, refs: [Int64], tags: [(String, String)])] = []
        var nodes: [Int64] = []
        for i in Int64(0)..<5_000 {
            nodes.append(i * 2 + 1)
            ways.append((i + 1, [i * 2 + 1, (i * 2 + 3)], [("highway", "track")]))
        }
        nodes.append(10_001)
        let url = try extract("many.osm.pbf", ways: ways, nodes: nodes)
        let network = try RoadNetworkLoader(url: url).load()
        XCTAssertEqual(network.wayCount, 5_000)
        for way in 0..<network.wayCount {
            let range = network.points(of: way)
            XCTAssertEqual(range.count, 2, "way \(way)")
            XCTAssertEqual(network.refs[range.lowerBound], Int64(way) * 2 + 1)
            XCTAssertGreaterThan(network.lat[range.lowerBound], 44.5)
        }
    }
}
