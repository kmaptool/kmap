import XCTest
@testable import kmap

/// Sorting the ids a pass has gathered, across the cores.
///
/// Everything downstream walks the file once against this list and assumes it ascends
/// with no repeats.
final class IDSortTests: XCTestCase {

    private func shuffled(_ count: Int, seed: UInt64) -> [Int64] {
        var state = seed
        return (0..<count).map { _ in
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Int64(bitPattern: state % 4_000_000_000)
        }
    }

    func testItSortsPastTheThresholdWhereItSplits() {
        // Either side of the size where it stops sorting in one piece.
        for count in [IDSort.leastWorthSplitting - 1,
                      IDSort.leastWorthSplitting,
                      IDSort.leastWorthSplitting + 1,
                      IDSort.leastWorthSplitting * 4 + 7] {
            var ids = shuffled(count, seed: 99)
            let expected = ids.sorted()
            IDSort.sort(&ids)
            XCTAssertEqual(ids, expected, "\(count) id(s)")
        }
    }

    func testACountThatIsNotAMultipleOfTheLanesStillSorts() {
        // The last chunk and the last merge are the short ones, and an off-by-one there
        // leaves a tail unsorted or reads past the end.
        for count in [70_001, 70_002, 70_003, 131_071, 131_073] {
            var ids = shuffled(count, seed: UInt64(count))
            let expected = ids.sorted()
            IDSort.sort(&ids)
            XCTAssertEqual(ids, expected, "\(count) id(s)")
        }
    }

    func testAlreadySortedAndReversedRunsAreHandled() {
        var ascending = (0..<200_000).map { Int64($0) }
        IDSort.sort(&ascending)
        XCTAssertEqual(ascending, (0..<200_000).map { Int64($0) })

        var descending = (0..<200_000).reversed().map { Int64($0) }
        IDSort.sort(&descending)
        XCTAssertEqual(descending, (0..<200_000).map { Int64($0) })
    }

    func testEmptyAndSingleAreNotUpsetting() {
        var none: [Int64] = []
        IDSort.sort(&none)
        XCTAssertEqual(none, [])
        var one: [Int64] = [7]
        IDSort.sort(&one)
        XCTAssertEqual(one, [7])
        XCTAssertEqual(IDSort.unique(of: []), [])
        XCTAssertEqual(IDSort.unique(of: [[], []]), [])
    }

    func testNegativeIDsSortBelowPositiveOnes() {
        // Objects the build invents carry negative ids, and they travel in the same lists.
        var ids: [Int64] = [5, -3, 0, .max, .min, -1, 2]
        IDSort.sort(&ids)
        XCTAssertEqual(ids, [.min, -3, -1, 0, 2, 5, .max])
    }

    func testUniqueJoinsTheRunsWithoutLosingOrRepeatingAnID() {
        let a = shuffled(90_000, seed: 3)
        let b = shuffled(90_000, seed: 4)
        let c: [Int64] = []
        XCTAssertEqual(IDSort.unique(of: [a, b, c]), Array(Set(a + b)).sorted())
    }

    func testUniqueCollapsesLongRunsOfTheSameID() {
        // Many ways naming the same junction; the dedupe makes one comparison per id.
        let ids = [Int64](repeating: 42, count: 300_000) + [7, 7, 9]
        XCTAssertEqual(IDSort.unique(of: [ids]), [7, 9, 42])
    }

    func testUniqueMatchesTheOneAtATimeAnswer() {
        for seed in [1, 2, 3, 11] as [UInt64] {
            let runs = [shuffled(40_000, seed: seed), shuffled(31_111, seed: seed &+ 100)]
            var plain = runs.flatMap { $0 }
            plain.sort()
            var expected: [Int64] = []
            for id in plain where expected.last != id { expected.append(id) }
            XCTAssertEqual(IDSort.unique(of: runs), expected, "seed \(seed)")
        }
    }
}
