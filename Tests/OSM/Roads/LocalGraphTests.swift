import XCTest

@testable import kmap

/// The routing graph built around the gaps, and the shortest-path search over it.
///
/// Answers how far a route would have to go round if a gap were left open, which decides
/// whether the gap is repaired.
final class LocalGraphTests: XCTestCase {
    private let metre = 1 / RoadRepair.metresPerDegree

    /// A graph of named nodes joined by hand, in metres.
    private func graph(_ edges: [(Int64, Int64, Double)]) -> LocalGraph {
        var graph = LocalGraph()
        for (a, b, metres) in edges { graph.link(a, b, metres) }
        return graph
    }

    func testAWayRoundIsMeasuredAlongTheEdges() {
        // 1 -- 2 -- 3, ten metres each.
        var g = graph([(1, 2, 10), (2, 3, 10)])
        XCTAssertEqual(g.detour(from: 1, to: (3, 3), cap: 100) ?? 0, 20, accuracy: 0.001)
    }

    func testTheShorterOfTwoWaysRoundIsTheAnswer() {
        var g = graph([
            (1, 2, 10), (2, 4, 10),  // twenty
            (1, 3, 3), (3, 4, 4)
        ])  // seven
        XCTAssertEqual(g.detour(from: 1, to: (4, 4), cap: 100) ?? 0, 7, accuracy: 0.001)
    }

    func testEitherOfTwoTargetsWillDo() {
        // The pair is the two ends of the segment a loose end reaches for.
        var g = graph([(1, 2, 5), (2, 3, 100)])
        XCTAssertEqual(g.detour(from: 1, to: (3, 2), cap: 1000) ?? 0, 5, accuracy: 0.001)
    }

    func testAWayRoundPastTheCapIsNoWayRound() {
        var g = graph([(1, 2, 300), (2, 3, 300)])
        XCTAssertNil(g.detour(from: 1, to: (3, 3), cap: 400))
    }

    func testNoConnectionAtAllIsNoWayRound() {
        var g = graph([(1, 2, 10), (3, 4, 10)])
        XCTAssertNil(g.detour(from: 1, to: (4, 4), cap: 1000))
    }

    func testANodeTheGraphNeverHeardOfIsNoWayRound() {
        var g = graph([(1, 2, 10)])
        XCTAssertNil(g.detour(from: 99, to: (2, 2), cap: 1000))
        XCTAssertNil(g.detour(from: 1, to: (98, 99), cap: 1000))
    }

    func testAnEndReachingItsOwnNodeIsNoDistanceAtAll() {
        var g = graph([(1, 2, 10)])
        XCTAssertEqual(g.detour(from: 1, to: (1, 2), cap: 100) ?? -1, 0, accuracy: 0.001)
    }

    func testTheAnswerDoesNotChangeWhenAskedTwice() {
        // The search reuses its working memory between calls, so marks left by one call
        // must not reach the next.
        var g = graph([(1, 2, 10), (2, 3, 10), (3, 4, 10), (10, 11, 5)])
        let first = g.detour(from: 1, to: (4, 4), cap: 100)
        let other = g.detour(from: 10, to: (11, 11), cap: 100)
        let again = g.detour(from: 1, to: (4, 4), cap: 100)
        XCTAssertEqual(first ?? 0, 30, accuracy: 0.001)
        XCTAssertEqual(other ?? 0, 5, accuracy: 0.001)
        XCTAssertEqual(again ?? 0, 30, accuracy: 0.001)
    }

    func testALinkAddedLaterIsUsed() {
        // Repairs are added to the graph as they are made, so later gaps see the map as
        // earlier repairs left it.
        var g = graph([(1, 2, 10), (3, 4, 10)])
        XCTAssertNil(g.detour(from: 1, to: (4, 4), cap: 1000))
        g.link(2, 3, 1)
        XCTAssertEqual(g.detour(from: 1, to: (4, 4), cap: 1000) ?? 0, 21, accuracy: 0.001)
    }

    func testANodeMergedIntoAnotherTakesItsConnectionsAlong() {
        var g = graph([(1, 2, 10), (3, 4, 10)])
        g.adopt(3, into: 2)  // node 3 is gone; node 2 stands for it
        XCTAssertEqual(g.detour(from: 1, to: (4, 4), cap: 1000) ?? 0, 20, accuracy: 0.001)
    }

    func testMergingANodeTheGraphNeverHeardOfChangesNothing() {
        var g = graph([(1, 2, 10)])
        g.adopt(99, into: 2)
        XCTAssertEqual(g.detour(from: 1, to: (2, 2), cap: 100) ?? 0, 10, accuracy: 0.001)
    }

    func testAGraphOfManyNodesStillFindsTheShortWay() {
        // A thousand-node chain with a short cut across it.
        var edges: [(Int64, Int64, Double)] = []
        for i in Int64(1)..<1_000 { edges.append((i, i + 1, 10)) }
        edges.append((1, 999, 15))
        var g = graph(edges)
        XCTAssertEqual(
            g.detour(from: 1, to: (1000, 1000), cap: 10_000) ?? 0,
            25,
            accuracy: 0.001
        )
    }

    // MARK: Building it from a network

    func testOnlyTheGroundAroundACandidateIsBuilt() {
        // Only ways near a candidate are added; a distant one cannot be part of any answer.
        var network = RoadNetwork()
        func addWay(_ id: Int64, _ points: [(Double, Double)], refs: [Int64]) {
            for (index, point) in points.enumerated() {
                network.refs.append(refs[index])
                network.lat.append(point.0)
                network.lon.append(point.1)
            }
            network.wayID.append(id)
            network.level.append(0)
            network.start.append(Int32(network.refs.count))
        }
        addWay(10, [(45, 33), (45, 33.001)], refs: [1, 2])
        addWay(11, [(45, 33.001), (45, 33.002)], refs: [2, 3])
        addWay(12, [(50, 40), (50, 40.001)], refs: [4, 5])  // far away

        let candidate = RoadRepair.Candidate(way: 0, atEnd: false)
        var g = LocalGraph(network: network, around: [candidate])
        XCTAssertNotNil(g.detour(from: 1, to: (3, 3), cap: 1000))
        XCTAssertNil(g.detour(from: 4, to: (5, 5), cap: 1000))
    }

    func testEdgeLengthsComeOutInMetres() {
        var network = RoadNetwork()
        network.refs = [1, 2]
        network.lat = [45, 45 + 100 / RoadRepair.metresPerDegree]
        network.lon = [33, 33]
        network.wayID = [10]
        network.level = [0]
        network.start = [0, 2]
        var g = LocalGraph(
            network: network,
            around: [RoadRepair.Candidate(way: 0, atEnd: false)]
        )
        XCTAssertEqual(g.detour(from: 1, to: (2, 2), cap: 1000) ?? 0, 100, accuracy: 0.5)
    }

    func testAMergeCarriesTheEdgesTheGraphWasBuiltWith() {
        // 2 ways built from the network, 1-2-3 and 4-5, 100 m a step. Node 4 merged into
        // node 3 brings its built edge along; a node linked after the build has none built.
        let step = 100 / RoadRepair.metresPerDegree
        var network = RoadNetwork()
        network.refs = [1, 2, 3, 4, 5]
        network.lat = [45, 45 + step, 45 + 2 * step, 45 + 2 * step, 45 + 3 * step]
        network.lon = [33, 33, 33, 33.0001, 33.0001]
        network.wayID = [10, 11]
        network.level = [0, 0]
        network.start = [0, 3, 5]
        var g = LocalGraph(network: network, around: [RoadRepair.Candidate(way: 0, atEnd: false)])
        XCTAssertNil(g.detour(from: 1, to: (5, 5), cap: 10_000), "not joined yet")
        g.adopt(4, into: 3)
        XCTAssertEqual(g.detour(from: 1, to: (5, 5), cap: 10_000) ?? 0, 300, accuracy: 1)
        // A node the build never saw, linked on: it has no built edges, only linked ones.
        g.link(5, 9, 50)
        XCTAssertEqual(g.detour(from: 1, to: (9, 9), cap: 10_000) ?? 0, 350, accuracy: 1)
        // Merged into 1, node 9 hands over its linked edge too: 2-1-5 is 100 + 50 m.
        g.adopt(9, into: 1)
        XCTAssertEqual(g.detour(from: 2, to: (5, 5), cap: 10_000) ?? 0, 150, accuracy: 1)
    }
}
