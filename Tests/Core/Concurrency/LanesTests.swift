import XCTest

@testable import kmap

/// Work spread over lanes comes back whole and in order, whatever the count and lanes.
final class LanesTests: XCTestCase {
    /// Every count against every lane count, the counts where the last lanes asked for
    /// would start past the end among them.
    func testEveryItemComesBackInOrderWhateverTheCountAndLanes() {
        for count in 0...300 {
            for lanes in 1...64 {
                let plain = Lanes.map(count, lanes: lanes) { $0 * 2 }
                XCTAssertEqual(plain, (0..<count).map { $0 * 2 }, "count \(count), lanes \(lanes)")
            }
        }
    }

    /// The scratch is made once per lane and handed to each of its items.
    func testEachLaneHandsItsScratchToEveryItemItReads() {
        for (count, lanes) in [(0, 4), (1, 4), (13, 12), (17, 16), (300, 7)] {
            let read = Lanes.map(count, lanes: lanes, scratch: { [Int]() }) { seen, at in
                seen.append(at)
                return (at, seen.count)
            }
            XCTAssertEqual(read.map(\.0), Array(0..<count))
            // Within a lane the scratch grows by 1 an item, so no item sees a fresh one
            // but the first of its lane.
            XCTAssertEqual(
                read.filter { $0.1 == 1 }.count,
                count == 0 ? 0 : (count + (count + lanes - 1) / lanes - 1) / ((count + lanes - 1) / lanes)
            )
        }
    }
}
