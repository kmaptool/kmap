import XCTest
@testable import kmap

/// The "certainly not" test in front of the rewrite's tables.
///
/// It may never deny an id that is present. A yes for an absent id costs only the
/// dictionary lookup behind it.
final class IDFilterTests: XCTestCase {

    func testEveryIDPutInIsFound() {
        let ids: [Int64] = (0..<5000).map { Int64($0) * 7919 + 1_000_000_000 }
        let filter = IDFilter(ids)
        for id in ids { XCTAssertTrue(filter.mayContain(id), "\(id) was put in and denied") }
    }

    func testConsecutiveIDsAreFound() {
        // OSM hands out ids in long ascending runs, and a filter keyed on the low bits
        // would file a whole neighbourhood into one word.
        let ids: [Int64] = Array(9_000_000_000..<9_000_010_000)
        let filter = IDFilter(ids)
        for id in ids { XCTAssertTrue(filter.mayContain(id)) }
    }

    func testAnEmptyFilterSaysNoToEverything() {
        XCTAssertFalse(IDFilter().mayContain(1))
        XCTAssertFalse(IDFilter([]).mayContain(1))
        XCTAssertTrue(IDFilter().isEmpty)
        XCTAssertTrue(IDFilter([]).isEmpty)
        XCTAssertFalse(IDFilter([1]).isEmpty)
    }

    func testNegativeAndExtremeIDsAreFound() {
        // Ids invented by the build itself are negative, and nothing stops OSM reaching
        // the top of the range.
        let ids: [Int64] = [-1, -2, -999_999, 0, 1, .max, .min, .max - 1]
        let filter = IDFilter(ids)
        for id in ids { XCTAssertTrue(filter.mayContain(id), "\(id)") }
    }

    func testASingleIDDoesNotMatchEverything() {
        let filter = IDFilter([42])
        XCTAssertTrue(filter.mayContain(42))
        var wrong = 0
        for id in Int64(0)..<10_000 where id != 42 && filter.mayContain(id) { wrong += 1 }
        // A 512-bit floor over two probes: a stray yes is possible, a flood is not.
        XCTAssertLessThan(wrong, 200)
    }

    func testTheFalseYesRateIsSmallEnoughToBeWorthIt() {
        // At sixteen bits an id and two probes the expected false-yes rate is near one in
        // five hundred; the bound below leaves slack.
        let ids: [Int64] = (0..<20_000).map { Int64($0) * 104_729 }
        let filter = IDFilter(ids)
        let present = Set(ids)
        var yes = 0, asked = 0
        for candidate in (0..<200_000).map({ Int64($0) * 31 + 7 }) where !present.contains(candidate) {
            asked += 1
            if filter.mayContain(candidate) { yes += 1 }
        }
        XCTAssertGreaterThan(asked, 100_000)
        XCTAssertLessThan(Double(yes) / Double(asked), 0.02,
                          "\(yes) false yes in \(asked) — the filter has stopped paying")
    }

    func testItGrowsWithTheSetRatherThanStayingFixed() {
        // A fixed table would degrade to "yes, always" on a continent's worth of barriers.
        let many: [Int64] = (0..<100_000).map { Int64($0) * 15_485_863 }
        let filter = IDFilter(many)
        let present = Set(many)
        var yes = 0, asked = 0
        for candidate in (0..<100_000).map({ Int64($0) * 7 + 3 }) where !present.contains(candidate) {
            asked += 1
            if filter.mayContain(candidate) { yes += 1 }
        }
        XCTAssertLessThan(Double(yes) / Double(asked), 0.02)
    }
}
