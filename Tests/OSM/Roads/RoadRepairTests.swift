import XCTest
@testable import kmap

/// Finding the road ends OSM left short of the line they were drawn for.
///
/// Mostly about which pairs are *not* candidates: ends that already meet, ends on
/// different decks, and two ends of the same way.
final class RoadRepairTests: XCTestCase {

    /// Metres per degree of latitude, for laying out test geometry by hand.
    private let metre = 1 / RoadRepair.metresPerDegree

    /// A network of straight ways, each given as its points in degrees.
    private func network(_ ways: [(id: Int64, level: Int32,
                                   points: [(lat: Double, lon: Double)])]) -> RoadNetwork {
        var network = RoadNetwork()
        var nextRef: Int64 = 1
        for way in ways {
            for point in way.points {
                network.refs.append(nextRef)
                network.lat.append(point.lat)
                network.lon.append(point.lon)
                nextRef += 1
            }
            network.wayID.append(way.id)
            network.level.append(way.level)
            network.start.append(Int32(network.refs.count))
        }
        return network
    }

    // MARK: The geometry

    func testDistanceToASegmentIsMeasuredInMetres() {
        let kx = RoadRepair.metresPerDegree * cos(45 * .pi / 180)
        // A point ten metres north of a segment running east.
        let (distance, along) = RoadRepair.project(45 + 10 * metre, 33.0,
                                                   45, 32.9, 45, 33.1, kx)
        XCTAssertEqual(distance, 10, accuracy: 0.1)
        XCTAssertEqual(along, 0.5, accuracy: 0.01)
    }

    func testAPointBeyondTheEndOfASegmentMeasuresToTheEnd() {
        let kx = RoadRepair.metresPerDegree
        // Well past the far end: the nearest place on the segment is that end.
        let (distance, along) = RoadRepair.project(0, 0.001, 0, 0, 0, 0.0005, kx)
        XCTAssertEqual(along, 1)
        XCTAssertEqual(distance, 0.0005 * RoadRepair.metresPerDegree, accuracy: 0.5)

        let (before, at) = RoadRepair.project(0, -0.001, 0, 0, 0, 0.0005, kx)
        XCTAssertEqual(at, 0)
        XCTAssertEqual(before, 0.001 * RoadRepair.metresPerDegree, accuracy: 0.5)
    }

    func testASegmentOfZeroLengthIsStillMeasurable() {
        // Dividing by a zero length would give a NaN, which compares false against every
        // limit.
        let (distance, along) = RoadRepair.project(0, 10 * metre, 0, 0, 0, 0, 
                                                   RoadRepair.metresPerDegree)
        XCTAssertEqual(distance, 10, accuracy: 0.1)
        XCTAssertEqual(along, 0)
        XCTAssertFalse(distance.isNaN)
    }

    func testAPointOnTheSegmentIsAtNoDistance() {
        let (distance, _) = RoadRepair.project(0, 0.00025, 0, 0, 0, 0.0005,
                                               RoadRepair.metresPerDegree)
        XCTAssertEqual(distance, 0, accuracy: 1e-6)
    }

    // MARK: Which ends are loose

    func testAnEndSharedWithAnotherWayIsNotLoose() {
        var net = RoadNetwork()
        // Two ways meeting at node 2.
        net.refs = [1, 2, 2, 3]
        net.lat = [0, 0, 0, 0]
        net.lon = [0, 0.001, 0.001, 0.002]
        net.wayID = [10, 11]
        net.level = [0, 0]
        net.start = [0, 2, 4]

        let loose = RoadRepair.looseEnds(of: net)
        XCTAssertTrue(loose[0])          // way 10's first point, node 1
        XCTAssertFalse(loose[1])         // way 10's last point, node 2 -- shared
        XCTAssertFalse(loose[2])         // way 11's first point, node 2 -- shared
        XCTAssertTrue(loose[3])          // way 11's last point, node 3
    }

    func testAClosedWayHasNoLooseEnds() {
        var net = RoadNetwork()
        net.refs = [1, 2, 3, 1]
        net.lat = [0, 0, 0.001, 0]
        net.lon = [0, 0.001, 0.001, 0]
        net.wayID = [10]
        net.level = [0]
        net.start = [0, 4]
        let loose = RoadRepair.looseEnds(of: net)
        XCTAssertFalse(loose[0])
        XCTAssertFalse(loose[1])
    }

    func testANodeUsedInTheMiddleOfAnotherWayStillCountsAsShared() {
        var net = RoadNetwork()
        net.refs = [1, 2, 3, 4, 2, 5]
        net.lat = [0, 0, 0, 0, 0, 0]
        net.lon = [0, 0.001, 0.002, 0, 0.001, 0.003]
        net.wayID = [10, 11]
        net.level = [0, 0]
        net.start = [0, 3, 6]
        let loose = RoadRepair.looseEnds(of: net)
        XCTAssertTrue(loose[0])          // node 1
        XCTAssertTrue(loose[1])          // node 3
        XCTAssertTrue(loose[2])          // node 4
        XCTAssertTrue(loose[3])          // node 5
    }

    // MARK: Candidates

    func testAnEndStoppingShortOfALineIsFound() {
        // A track ending two metres from a road running past it.
        let net = network([
            (10, 0, [(45, 33), (45, 33.001)]),
            (11, 0, [(45 + 2 * metre, 33.0005), (45 + 0.001, 33.0005)]),
        ])
        let (found, _) = RoadRepair(network: net, limit: 5).candidates()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].way, 1)
        XCTAssertFalse(found[0].atEnd)
        XCTAssertEqual(found[0].otherWay, 0)
        XCTAssertEqual(found[0].distance, 2, accuracy: 0.2)
        XCTAssertEqual(found[0].along, 0.5, accuracy: 0.05)
    }

    func testAGapWiderThanTheLimitIsNotACandidate() {
        let net = network([
            (10, 0, [(45, 33), (45, 33.001)]),
            (11, 0, [(45 + 20 * metre, 33.0005), (45 + 0.001, 33.0005)]),
        ])
        let (found, _) = RoadRepair(network: net, limit: 5).candidates()
        XCTAssertTrue(found.isEmpty)
    }

    func testAnEndIsNeverJoinedToItsOwnWay() {
        // A hairpin coming back within a metre of itself is already one road.
        let net = network([
            (10, 0, [(45, 33), (45, 33.001), (45 + 1 * metre, 33.0005)]),
        ])
        let (found, _) = RoadRepair(network: net, limit: 5).candidates()
        XCTAssertTrue(found.isEmpty)
    }

    func testEndsOnDifferentDecksAreNotJoined() {
        // Ends a metre apart on the map but on different levels.
        let net = network([
            (10, 0, [(45, 33), (45, 33.001)]),
            (11, 2, [(45 + 1 * metre, 33.0005), (45 + 0.001, 33.0005)]),
        ])
        let (found, _) = RoadRepair(network: net, limit: 5).candidates()
        XCTAssertTrue(found.isEmpty)
    }

    func testAnEndAlreadyOnTheOtherLineIsNotACandidate() {
        // The two ends share a node.
        var net = network([
            (10, 0, [(45, 33), (45, 33.001)]),
            (11, 0, [(45, 33.001), (45 + 0.001, 33.001)]),
        ])
        net.refs[2] = net.refs[1]        // way 11 starts on way 10's last node
        let (found, _) = RoadRepair(network: net, limit: 5).candidates()
        XCTAssertTrue(found.isEmpty)
    }

    func testTheNearestLineIsTheOneKept() {
        let net = network([
            (10, 0, [(45 + 4 * metre, 33), (45 + 4 * metre, 33.001)]),
            (11, 0, [(45 - 1 * metre, 33), (45 - 1 * metre, 33.001)]),
            (12, 0, [(45, 33.0005), (45 + 0.001, 33.0005)]),
        ])
        let (found, _) = RoadRepair(network: net, limit: 5).candidates()
        // The southern end of way 12: a road four metres north, another a metre south.
        let mine = found.first { $0.way == 2 && !$0.atEnd }
        XCTAssertEqual(mine?.otherWay, 1)             // the one a metre away
        XCTAssertEqual(mine?.distance ?? 0, 1, accuracy: 0.2)
    }

    func testBothEndsOfAWayCanBeCandidates() {
        let net = network([
            (10, 0, [(45, 33), (45, 33.002)]),
            (11, 0, [(45 + 2 * metre, 33.0005), (45 + 2 * metre, 33.0015)]),
        ])
        let (found, _) = RoadRepair(network: net, limit: 5).candidates()
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(Set(found.map(\.atEnd)), [false, true])
    }

    func testAnEndFarFromEverythingIsNotACandidate() {
        let net = network([
            (10, 0, [(45, 33), (45, 33.001)]),
            (11, 0, [(46, 34), (46, 34.001)]),
        ])
        let (found, _) = RoadRepair(network: net, limit: 5).candidates()
        XCTAssertTrue(found.isEmpty)
    }

    func testALongSegmentIsStillNoticedByAnEndBesideItsMiddle() {
        // The segment crosses many grid cells and the end sits beside its middle.
        let net = network([
            (10, 0, [(45, 33), (45, 33.05)]),
            (11, 0, [(45 + 2 * metre, 33.025), (45 + 0.001, 33.025)]),
        ])
        let (found, _) = RoadRepair(network: net, limit: 5).candidates()
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].distance, 2, accuracy: 0.2)
    }

    func testASegmentRunningNorthIsNoticedToo() {
        // The cell walk steps along whichever axis is longer.
        let net = network([
            (10, 0, [(45, 33), (45.05, 33)]),
            (11, 0, [(45.025, 33 + 2 * metre), (45.025, 33 + 0.001)]),
        ])
        let (found, _) = RoadRepair(network: net, limit: 5).candidates()
        XCTAssertEqual(found.count, 1)
    }
}
