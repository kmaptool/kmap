import XCTest
@testable import kmap

/// Finding where a wanted set of nodes are.
///
/// A PBF puts its nodes before the ways that name them, so a pass working with way
/// geometry reads the file twice and picks its nodes out of the second read.
final class NodePlacesTests: XCTestCase {

    private func block(_ pairs: [(Int64, Double, Double)]) -> BlockNodes {
        var out = BlockNodes()
        for (id, lat, lon) in pairs {
            out.ids.append(id); out.lat.append(lat); out.lon.append(lon)
        }
        return out
    }

    // MARK: The walk

    func testItPicksTheWantedNodesOutOfAFileHoldingManyMore() {
        var places = NodePlaces(wanted: [2, 5, 9])
        places.take(block([(1, 1, 1), (2, 20, 30), (3, 3, 3), (5, 50, 60),
                           (7, 7, 7), (9, 90, 100)]))
        XCTAssertEqual(places.place(of: 2)?.lat, 20)
        XCTAssertEqual(places.place(of: 5)?.lon, 60)
        XCTAssertEqual(places.place(of: 9)?.lat, 90)
        XCTAssertNil(places.place(of: 3))          // in the file, never asked for
        XCTAssertNil(places.place(of: 4))          // in neither
    }

    func testANodeTheFileDoesNotCarryStaysUnknownRatherThanBecomingZero() {
        // An extract is cut out of a bigger one and the cut runs through ways; filling in
        // 0,0 would invent a position.
        var places = NodePlaces(wanted: [2, 5, 9])
        places.take(block([(2, 20, 30), (9, 90, 100)]))
        XCTAssertNil(places.place(of: 5))
        XCTAssertNotNil(places.place(of: 2))
        XCTAssertNotNil(places.place(of: 9))
    }

    func testTheWalkContinuesAcrossBlocks() {
        var places = NodePlaces(wanted: [2, 5, 9])
        places.take(block([(1, 1, 1), (2, 20, 30)]))
        places.take(block([(5, 50, 60)]))
        places.take(block([(8, 8, 8), (9, 90, 100)]))
        for id in [Int64(2), 5, 9] { XCTAssertNotNil(places.place(of: id), "\(id)") }
    }

    func testAFileWhoseIdsDoNotAscendIsStillReadCorrectly() {
        // The merge assumes ascending ids and the second read would find nothing after the
        // first step backwards, so it starts the walk over instead.
        var places = NodePlaces(wanted: [2, 5, 9])
        places.take(block([(5, 50, 60), (9, 90, 100)]))
        places.take(block([(2, 20, 30)]))          // back down
        XCTAssertEqual(places.place(of: 2)?.lat, 20)
        XCTAssertEqual(places.place(of: 5)?.lat, 50)
        XCTAssertEqual(places.place(of: 9)?.lat, 90)
    }

    func testANodeRepeatedInTheFileKeepsTheFirstPlaceItWasGiven() {
        var places = NodePlaces(wanted: [5])
        places.take(block([(5, 50, 60), (5, 11, 12)]))
        XCTAssertEqual(places.place(of: 5)?.lat, 50)
    }

    func testNegativeIdsAreOrdinaryHere() {
        // Nodes the build invents for a repair carry them.
        var places = NodePlaces(wanted: [-9, -2, 4])
        places.take(block([(-9, 1, 1), (-5, 0, 0), (-2, 2, 2), (4, 4, 4)]))
        XCTAssertEqual(places.place(of: -9)?.lat, 1)
        XCTAssertEqual(places.place(of: -2)?.lat, 2)
        XCTAssertEqual(places.place(of: 4)?.lat, 4)
    }

    func testAskingForNothingIsNotAnError() {
        var places = NodePlaces(wanted: [])
        places.take(block([(1, 1, 1), (2, 2, 2)]))
        XCTAssertNil(places.place(of: 1))
        XCTAssertNil(places.index(of: 1))
    }

    // MARK: The lookup, either side of the fence table

    func testTheLookupIsRightWhetherOrNotTheFenceTableWasBuilt() {
        // Fences are only worth building past a few thousand ids, so both paths exist and
        // both have to give the same answers.
        for count in [10, 4096, 4097, 20_000] {
            let wanted = (0..<count).map { Int64($0) * 3 }
            var places = NodePlaces(wanted: wanted)
            places.take(block(wanted.map { ($0, Double($0), Double($0) + 0.5) }))
            for probe in [0, 1, count / 2, count - 1] {
                XCTAssertEqual(places.index(of: wanted[probe]), probe, "\(count) at \(probe)")
                XCTAssertEqual(places.place(of: wanted[probe])?.lat,
                               Double(wanted[probe]), "\(count) at \(probe)")
            }
            // Between two wanted ids, before the first and after the last.
            XCTAssertNil(places.index(of: wanted[count / 2] + 1), "\(count)")
            XCTAssertNil(places.index(of: -1), "\(count)")
            XCTAssertNil(places.index(of: wanted[count - 1] + 1), "\(count)")
        }
    }

    func testAnIdSittingExactlyOnAFenceIsFound() {
        // The fences are every 4096th id; an off-by-one in choosing the page between them
        // loses precisely these.
        let wanted = (0..<20_000).map { Int64($0) * 7 }
        var places = NodePlaces(wanted: wanted)
        places.take(block(wanted.map { ($0, Double($0), 0) }))
        for index in [4096, 8192, 12_288, 16_384, 4095, 4097] {
            XCTAssertEqual(places.index(of: wanted[index]), index, "\(index)")
        }
    }

    func testEveryWantedIdIsFoundAndNothingElseIs() {
        // The whole contract, over a set with gaps of every size.
        var state: UInt64 = 12345
        var ids = Set<Int64>()
        while ids.count < 9000 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            ids.insert(Int64(state % 500_000))
        }
        let wanted = ids.sorted()
        var places = NodePlaces(wanted: wanted)
        places.take(block(wanted.map { ($0, Double($0), Double(-$0)) }))
        for id in wanted {
            XCTAssertEqual(places.place(of: id)?.lat, Double(id))
            XCTAssertEqual(places.place(of: id)?.lon, Double(-id))
        }
        for candidate in Int64(0)..<500_000 where !ids.contains(candidate) {
            XCTAssertNil(places.index(of: candidate), "\(candidate) was never asked for")
        }
    }

    // MARK: Gathering the ids to ask about

    func testTheWantedListComesOutSortedAndWithoutRepeats() {
        // Ways name the same junction over and over; the walk needs each id once, in order.
        XCTAssertEqual(NodePlaces.wantedIDs(from: [5, 2, 5, 9, 2, 2]), [2, 5, 9])
        XCTAssertEqual(NodePlaces.wantedIDs(from: [Int64]()), [])
        XCTAssertEqual(NodePlaces.wantedIDs(from: [[3, 1], [2, 3], []]), [1, 2, 3])
    }
}
