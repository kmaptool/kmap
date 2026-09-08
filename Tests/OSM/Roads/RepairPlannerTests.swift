import XCTest
@testable import kmap

/// Deciding which candidate gaps are broken junctions, and what to do about each.
///
/// Each rule has its own test, and the verdict is checked by the name the pass counts it
/// under.
final class RepairPlannerTests: XCTestCase {

    private let metre = 1 / RoadRepair.metresPerDegree

    private struct Line {
        var id: Int64
        var points: [(lat: Double, lon: Double)]
        var level: Int32 = 0
    }

    private struct Obstacle {
        var kind: ObstacleKind
        var word: String
        var height: Float = .nan
        var points: [(lat: Double, lon: Double)]
    }

    /// A network of roads and obstacles laid out by hand.
    private func network(_ roads: [Line], obstacles: [Obstacle] = []) -> RoadNetwork {
        var network = RoadNetwork()
        var nextRef: Int64 = 1
        for road in roads {
            for point in road.points {
                network.refs.append(nextRef)
                network.lat.append(point.lat)
                network.lon.append(point.lon)
                nextRef += 1
            }
            network.wayID.append(road.id)
            network.level.append(road.level)
            network.start.append(Int32(network.refs.count))
        }
        for obstacle in obstacles {
            for point in obstacle.points {
                network.obstacleLat.append(point.lat)
                network.obstacleLon.append(point.lon)
            }
            network.obstacleKind.append(obstacle.kind.rawValue)
            if let known = network.vocabulary.firstIndex(of: obstacle.word) {
                network.obstacleWord.append(UInt8(known))
            } else {
                network.vocabulary.append(obstacle.word)
                network.obstacleWord.append(UInt8(network.vocabulary.count - 1))
            }
            network.obstacleHeight.append(obstacle.height)
            network.obstacleStart.append(Int32(network.obstacleLat.count))
        }
        return network
    }

    private func plan(_ network: RoadNetwork, limit: Double = 5,
                      bridging: Bool = false) -> RepairPlan {
        let (found, loose) = RoadRepair(network: network, limit: limit).candidates()
        return RepairPlanner(network: network, terrain: nil, bridging: bridging,
                             limit: limit).plan(found, loose: loose)
    }

    /// A track ending two metres short of a road that runs past it.
    private var shortOfARoad: RoadNetwork {
        network([
            Line(id: 10, points: [(45, 33), (45, 33.002)]),
            Line(id: 11, points: [(45 + 2 * metre, 33.001), (45 + 0.002, 33.001)]),
        ])
    }

    // MARK: Joining

    func testAnEndStoppingShortOfALineIsJoinedToIt() {
        let result = plan(shortOfARoad)
        XCTAssertEqual(result.counts["joined"], 1)
        // The end moves onto the line; the line is not bent to reach it.
        XCTAssertEqual(result.inserts.count, 1)
        XCTAssertEqual(result.moves.count, 1)
    }

    func testTwoEndsReachingForEachOtherBecomeOneNode() {
        // Neither line grows a vertex: the two ends share one node.
        let result = plan(network([
            Line(id: 10, points: [(45, 33), (45, 33.001)]),
            Line(id: 11, points: [(45, 33.001 + 2 * metre), (45, 33.003)]),
        ]))
        XCTAssertEqual(result.counts["joined"], 1)
        XCTAssertEqual(result.merges.count, 1)
        XCTAssertTrue(result.inserts.isEmpty)
    }

    func testAnEndAlreadyOnTheLineIsLeftAlone() {
        var net = network([
            Line(id: 10, points: [(45, 33), (45, 33.002)]),
            Line(id: 11, points: [(45, 33.001), (45, 33.003)]),
        ])
        net.refs[2] = net.refs[0]        // way 11 starts on a node way 10 already has
        let result = plan(net)
        XCTAssertNil(result.counts["joined"])
    }

    // MARK: What stands in the way

    func testAFenceBetweenTheEndsStopsTheRepair() {
        let result = plan(network([
            Line(id: 10, points: [(45, 33), (45, 33.002)]),
            Line(id: 11, points: [(45 + 2 * metre, 33.001), (45 + 0.002, 33.001)]),
        ], obstacles: [
            Obstacle(kind: .fence, word: "fence",
                     points: [(45 + 1 * metre, 33.0005), (45 + 1 * metre, 33.0015)]),
        ]))
        XCTAssertEqual(result.counts["stopped by fence"], 1)
        XCTAssertNil(result.counts["joined"])
    }

    func testABuildingBetweenTheEndsStopsTheRepair() {
        let result = plan(network([
            Line(id: 10, points: [(45, 33), (45, 33.002)]),
            Line(id: 11, points: [(45 + 2 * metre, 33.001), (45 + 0.002, 33.001)]),
        ], obstacles: [
            Obstacle(kind: .building, word: "building",
                     points: [(45 + 1 * metre, 33.0005), (45 + 1 * metre, 33.0015)]),
        ]))
        XCTAssertEqual(result.counts["stopped by building"], 1)
    }

    func testACrossableObstacleStopsTheRepairWhenBridgingIsOff() {
        // Without bridging the map cannot show the obstacle, so the gap is left open.
        let result = plan(network([
            Line(id: 10, points: [(45, 33), (45, 33.002)]),
            Line(id: 11, points: [(45 + 2 * metre, 33.001), (45 + 0.002, 33.001)]),
        ], obstacles: [
            Obstacle(kind: .barrier, word: "kerb",
                     points: [(45 + 1 * metre, 33.0005), (45 + 1 * metre, 33.0015)]),
        ]))
        XCTAssertEqual(result.counts["stopped by kerb"], 1)
    }

    func testACrossableObstacleIsBridgedWhenBridgingIsOn() {
        // The gap is closed by a link of its own, named after what it crosses.
        let result = plan(network([
            Line(id: 10, points: [(45, 33), (45, 33.002)]),
            Line(id: 11, points: [(45 + 2 * metre, 33.001), (45 + 0.002, 33.001)]),
        ], obstacles: [
            Obstacle(kind: .barrier, word: "kerb",
                     points: [(45 + 1 * metre, 33.0005), (45 + 1 * metre, 33.0015)]),
        ]), bridging: true)
        XCTAssertEqual(result.counts["bridged over kerb"], 1)
        XCTAssertEqual(result.bridges.count, 1)
        XCTAssertEqual(result.bridges.first?.word, "kerb")
    }

    func testSomethingTooHighToClimbIsNotBridged() {
        let result = plan(network([
            Line(id: 10, points: [(45, 33), (45, 33.002)]),
            Line(id: 11, points: [(45 + 2 * metre, 33.001), (45 + 0.002, 33.001)]),
        ], obstacles: [
            Obstacle(kind: .barrier, word: "retaining_wall", height: 3,
                     points: [(45 + 1 * metre, 33.0005), (45 + 1 * metre, 33.0015)]),
        ]), bridging: true)
        XCTAssertEqual(result.counts["stopped by retaining_wall over 2 m high"], 1)
        XCTAssertTrue(result.bridges.isEmpty)
    }

    func testAnObstacleBesideTheGapDoesNotBlockIt() {
        // The obstacle must be crossed by the gap, not merely near it.
        let result = plan(network([
            Line(id: 10, points: [(45, 33), (45, 33.002)]),
            Line(id: 11, points: [(45 + 2 * metre, 33.001), (45 + 0.002, 33.001)]),
        ], obstacles: [
            Obstacle(kind: .fence, word: "fence",
                     points: [(45 + 1 * metre, 33.0016), (45 + 0.001, 33.0016)]),
        ]))
        XCTAssertEqual(result.counts["joined"], 1)
    }

    // MARK: Lines that merely run alongside

    func testAPavementRunningBesideARoadIsNotAJunction() {
        // Parallel and close along their whole length.
        let result = plan(network([
            Line(id: 10, points: [(45, 33), (45, 33.004)]),
            Line(id: 11, points: [(45 + 2 * metre, 33.001), (45 + 2 * metre, 33.003)]),
        ]))
        XCTAssertEqual(result.counts["running alongside"], 2)
        XCTAssertNil(result.counts["joined"])
    }

    func testAnEndMeetingALineSquarelyIsAJunction() {
        // The same distance as a parallel pair, but arriving at a right angle.
        let result = plan(shortOfARoad)
        XCTAssertNil(result.counts["running alongside"])
        XCTAssertEqual(result.counts["joined"], 1)
    }

    func testASwitchbackArrivingShallowIsStillAJunction() {
        // The last segment arrives at a pavement's shallow angle, but the way has left
        // the roadside further back, so the arrival angle alone cannot decide.
        let result = plan(network([
            Line(id: 10, points: [(45, 33), (45, 33.004)]),
            Line(id: 11, points: [(45 + 30 * metre, 33.0000),
                                  (45 + 9 * metre, 33.0016),
                                  (45 + 2 * metre, 33.0020)]),
        ]))
        XCTAssertNil(result.counts["running alongside"])
        XCTAssertEqual(result.counts["joined"], 1)
    }

    // MARK: Invented ids stay out of each other's way

    func testTwoPassesWithTheirOwnBasesInventDisjointNodes() {
        // Each extract is annotated by its own pass and the inventions meet in one
        // splitter stream, so each pass numbers from its own base.
        let roads = network([
            Line(id: 10, points: [(45, 33), (45, 33.002)]),
            Line(id: 11, points: [(45 + 2 * metre, 33.001), (45 + 0.002, 33.001)]),
        ], obstacles: [
            Obstacle(kind: .barrier, word: "kerb",
                     points: [(45 + 1 * metre, 33.0005), (45 + 1 * metre, 33.0015)]),
        ])
        let (found, loose) = RoadRepair(network: roads, limit: 5).candidates()
        let first = RepairPlanner(network: roads, terrain: nil, bridging: true,
                                  limit: 5, inventedIDBase: 1 << 40)
            .plan(found, loose: loose)
        let second = RepairPlanner(network: roads, terrain: nil, bridging: true,
                                   limit: 5, inventedIDBase: (1 << 40) + (1 << 32))
            .plan(found, loose: loose)
        let a = Set(first.bridges.map(\.node))
        let b = Set(second.bridges.map(\.node))
        XCTAssertFalse(a.isEmpty)
        XCTAssertTrue(a.isDisjoint(with: b),
                      "two regions' invented nodes must never share an id")
    }

    // MARK: A route that already gets through

    func testAGapWithAWayRoundIsLeftAlone() {
        // The lines already meet at their far ends; closing the gap would add a shortcut
        // that is not on the ground.
        var net = network([
            Line(id: 10, points: [(45, 33), (45, 33.0005), (45, 33.001)]),
            Line(id: 11, points: [(45 + 3 * metre, 33.001), (45 + 3 * metre, 33.0005),
                                  (45, 33)]),
        ])
        net.refs[5] = net.refs[0]         // way 11 ends on way 10's first node
        let result = plan(net)
        XCTAssertGreaterThanOrEqual(result.counts["already joined nearby"] ?? 0, 1)
        XCTAssertNil(result.counts["joined"])
    }

    func testAGapTooNarrowToMatterIsClosedEvenWithAWayRound() {
        // Under a metre the ends are within one coordinate unit of the finest zoom.
        var net = network([
            Line(id: 10, points: [(45, 33), (45, 33.0005), (45, 33.001)]),
            Line(id: 11, points: [(45 + 0.5 * metre, 33.001), (45 + 0.5 * metre, 33.0005),
                                  (45, 33)]),
        ])
        net.refs[5] = net.refs[0]
        let result = plan(net)
        XCTAssertEqual(result.counts["joined"] ?? 0, 1)
    }

    // MARK: Repairs seen by the repairs that follow

    func testThreeTracksMeetingOneRoadEachGetTheirOwnJunction() {
        // Each track is a separate way in, so each needs a junction of its own.
        var lines = [Line(id: 10, points: [(45, 33), (45, 33.01)])]
        for i in 0..<3 {
            let lon = 33.001 + Double(i) * 0.0004
            lines.append(Line(id: Int64(11 + i),
                              points: [(45 + 2 * metre, lon), (45 + 0.002, lon)]))
        }
        let result = plan(network(lines))
        XCTAssertEqual(result.counts["joined"], 3)
        XCTAssertEqual(result.inserts[0]?.count, 3)   // all three land on way 10
    }

    func testEveryVerdictIsCountedExactlyOnce() {
        let result = plan(shortOfARoad)
        XCTAssertEqual(result.counts.values.reduce(0, +), 1)
    }

    func testNothingToRepairLeavesAnEmptyPlan() {
        let result = plan(network([
            Line(id: 10, points: [(45, 33), (45, 33.002)]),
            Line(id: 11, points: [(46, 34), (46, 34.002)]),
        ]))
        XCTAssertTrue(result.moves.isEmpty)
        XCTAssertTrue(result.inserts.isEmpty)
        XCTAssertTrue(result.merges.isEmpty)
        XCTAssertTrue(result.bridges.isEmpty)
    }

    func testAMergeChainIsFlattenedSoOneSubstitutionIsEnough() {
        // Three ends meet in one place: no merge entry may point at a node that is itself
        // merged away.
        var lines: [Line] = []
        for i in 0..<3 {
            let lat = 45 + Double(i) * 0.5 * metre
            lines.append(Line(id: Int64(10 + i), points: [(lat, 33), (lat, 33.001)]))
        }
        let result = plan(network(lines))
        for (_, stands) in result.merges {
            XCTAssertNil(result.merges[stands], "a merge points at a node that is gone")
        }
    }
}

// MARK: - Roads that must not be joined

/// Cases where the verdict must be to leave the gap open: closing one wrongly puts a road
/// on the map that is not on the ground.
extension RepairPlannerTests {

    func testAPathUnderABridgeIsNotJoinedToIt() {
        // A metre apart on the map, but on different levels.
        let result = plan(network([
            Line(id: 10, points: [(45, 33), (45, 33.002)], level: 0),
            Line(id: 11, points: [(45 + 1 * metre, 33.001), (45 + 0.002, 33.001)], level: 2),
        ]))
        XCTAssertTrue(result.inserts.isEmpty)
        XCTAssertTrue(result.merges.isEmpty)
    }

    func testATunnelIsNotJoinedToTheRoadAboveIt() {
        let result = plan(network([
            Line(id: 10, points: [(45, 33), (45, 33.002)], level: 0),
            Line(id: 11, points: [(45 + 1 * metre, 33.001), (45 + 0.002, 33.001)], level: 1),
        ]))
        XCTAssertTrue(result.inserts.isEmpty)
        XCTAssertTrue(result.merges.isEmpty)
    }

    func testARiverBetweenTheEndsStopsTheRepair() {
        let result = plan(network([
            Line(id: 10, points: [(45, 33), (45, 33.002)]),
            Line(id: 11, points: [(45 + 3 * metre, 33.001), (45 + 0.002, 33.001)]),
        ], obstacles: [
            Obstacle(kind: .water, word: "river",
                     points: [(45 + 1.5 * metre, 33.0005), (45 + 1.5 * metre, 33.0015)]),
        ]))
        XCTAssertEqual(result.counts["stopped by river"], 1)
    }

    func testACliffBetweenTheEndsStopsTheRepair() {
        let result = plan(network([
            Line(id: 10, points: [(45, 33), (45, 33.002)]),
            Line(id: 11, points: [(45 + 3 * metre, 33.001), (45 + 0.002, 33.001)]),
        ], obstacles: [
            Obstacle(kind: .cliff, word: "cliff",
                     points: [(45 + 1.5 * metre, 33.0005), (45 + 1.5 * metre, 33.0015)]),
        ]))
        XCTAssertEqual(result.counts["stopped by cliff"], 1)
    }

    func testAFenceWinsOverBridgingBeingOn() {
        // Bridging applies to crossable obstacles only, whatever the height.
        let result = plan(network([
            Line(id: 10, points: [(45, 33), (45, 33.002)]),
            Line(id: 11, points: [(45 + 2 * metre, 33.001), (45 + 0.002, 33.001)]),
        ], obstacles: [
            Obstacle(kind: .fence, word: "fence", height: 0.5,
                     points: [(45 + 1 * metre, 33.0005), (45 + 1 * metre, 33.0015)]),
        ]), bridging: true)
        XCTAssertEqual(result.counts["stopped by fence"], 1)
        XCTAssertTrue(result.bridges.isEmpty)
    }

    func testAGapJustPastTheLimitIsNotEvenACandidate() {
        let result = plan(network([
            Line(id: 10, points: [(45, 33), (45, 33.002)]),
            Line(id: 11, points: [(45 + 5.4 * metre, 33.001), (45 + 0.002, 33.001)]),
        ]))
        XCTAssertTrue(result.counts.isEmpty)
    }

    func testAGapJustInsideTheLimitIsJoined() {
        let result = plan(network([
            Line(id: 10, points: [(45, 33), (45, 33.002)]),
            Line(id: 11, points: [(45 + 4.6 * metre, 33.001), (45 + 0.002, 33.001)]),
        ]))
        XCTAssertEqual(result.counts["joined"], 1)
    }

    func testAnEndPastTheEndOfAShortLineIsMeasuredToItsCornerNotItsLine() {
        // The nearest place on the other way is its last node, not the extension of its
        // line, which points straight at this end.
        let result = plan(network([
            Line(id: 10, points: [(45, 33), (45, 33.0002)]),
            Line(id: 11, points: [(45, 33.0004), (45, 33.001)]),
        ]))
        XCTAssertTrue(result.counts.isEmpty, "\(result.counts)")
    }

    func testTwoEndsInExactlyTheSamePlaceAreJoinedWithoutMovingAnything() {
        // Zero distance: the node still has to be shared, and nothing may be moved.
        let result = plan(network([
            Line(id: 10, points: [(45, 33), (45, 33.001)]),
            Line(id: 11, points: [(45, 33.001), (45, 33.002)]),
        ]))
        XCTAssertEqual(result.counts["joined"], 1)
        XCTAssertTrue(result.moves.isEmpty, "a join at no distance moved a node")
        XCTAssertEqual(result.merges.count, 1)
    }

    func testAnObstacleWayIsNeverTreatedAsARoadToJoin() {
        // An obstacle way is not routable, so it is no candidate to join to.
        let result = plan(network([
            Line(id: 10, points: [(45, 33), (45, 33.002)]),
        ], obstacles: [
            Obstacle(kind: .fence, word: "fence",
                     points: [(45 + 1 * metre, 33.002), (45 + 0.002, 33.002)]),
        ]))
        XCTAssertTrue(result.counts.isEmpty)
    }

    func testARoundaboutHasNoEndsToRepair() {
        // A closed way's first and last point are the same node, so neither is loose.
        var net = network([
            Line(id: 10, points: [(45, 33), (45.0001, 33), (45.0001, 33.0001),
                                  (45, 33.0001), (45, 33)]),
            Line(id: 11, points: [(45 + 2 * metre, 33.00005), (45 + 0.002, 33.00005)]),
        ])
        net.refs[4] = net.refs[0]
        let result = plan(net)
        XCTAssertNil(result.merges[net.refs[0]])
    }

    func testAWayWithTwoPointsInTheSamePlaceDoesNotConfuseTheGeometry() {
        // A zero-length segment must not divide by zero: a NaN compares false against
        // every limit.
        let result = plan(network([
            Line(id: 10, points: [(45, 33), (45, 33), (45, 33.002)]),
            Line(id: 11, points: [(45 + 2 * metre, 33.001), (45 + 0.002, 33.001)]),
        ]))
        XCTAssertEqual(result.counts["joined"], 1)
    }

    func testAnEndAlreadyMovedIsNotDraggedOffCourseByAThirdLine() {
        // Three lines meet near one point; a node already moved by one repair must not be
        // moved again by the next.
        var lines: [Line] = []
        lines.append(Line(id: 10, points: [(45, 33), (45, 33.001)]))
        lines.append(Line(id: 11, points: [(45 + 3 * metre, 33.001), (45 + 3 * metre, 33.002)]))
        lines.append(Line(id: 12, points: [(45 - 3 * metre, 33.001), (45 - 3 * metre, 33.002)]))
        let result = plan(network(lines))
        XCTAssertLessThanOrEqual(result.moves.count, 2)
        for (node, _) in result.moves {
            XCTAssertNil(result.merges[node], "a node was both moved and merged away")
        }
    }

    func testNothingIsJoinedWhenTheRadiusIsZero() {
        // A zero radius leaves the roads exactly as OSM has them.
        let result = plan(shortOfARoad, limit: 0)
        XCTAssertTrue(result.counts.isEmpty)
        XCTAssertTrue(result.inserts.isEmpty)
    }

    func testAnEndTouchingTheMiddleOfALineIsInsertedNotMerged() {
        // The nearest point is halfway along the far line, so there is no end to merge
        // with and the line takes a new vertex.
        let result = plan(network([
            Line(id: 10, points: [(45, 33), (45, 33.004)]),
            Line(id: 11, points: [(45 + 2 * metre, 33.002), (45 + 0.002, 33.002)]),
        ]))
        XCTAssertEqual(result.counts["joined"], 1)
        XCTAssertEqual(result.inserts.count, 1)
        XCTAssertTrue(result.merges.isEmpty)
    }
}
