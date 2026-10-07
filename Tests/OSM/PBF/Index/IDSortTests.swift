import CVector
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
        for count in [
            IDSort.leastWorthSplitting - 1,
            IDSort.leastWorthSplitting,
            IDSort.leastWorthSplitting + 1,
            IDSort.leastWorthSplitting * 4 + 7
        ] {
            var ids = shuffled(count, seed: 99)
            let expected = ids.sorted()
            IDSort.sort(&ids)
            XCTAssertEqual(ids, expected, "\(count) id(s)")
        }
    }

    /// Ids sharing their bytes sort in 0 or 1 pass.
    func testIdsThatShareTheirBytesNeedFewPasses() {
        for ids in [[Int64](repeating: 42, count: 1500), (0..<1500).map { $0 % 2 == 0 ? Int64.min : 0 }] {
            var sorted = ids
            var scratch = [Int64](repeating: 0, count: ids.count)
            let inScratch = sorted.withUnsafeMutableBufferPointer { ids in
                scratch.withUnsafeMutableBufferPointer {
                    kmap_sort_i64_either(ids.baseAddress, $0.baseAddress, ids.count)
                }
            }
            XCTAssertEqual(inScratch != 0 ? scratch : sorted, ids.sorted())
        }
        var none: [Int64] = []
        IDSort.sort(&none)
        XCTAssertEqual(none, [])
    }

    /// A stride of 0, or no keys or fences, finds nothing rather than dividing by 0.
    func testAFencedSearchWithNothingToSearchFindsNothing() {
        let keys: [Int64] = [1, 2, 3, 4]
        let fences: [Int64] = [1, 3]
        let ids: [Int64] = [1, 3, 5]
        for (stride, keyCount, fenceCount) in [(0, 4, 2), (2, 0, 2), (2, 4, 0)] {
            var out = [Int64](repeating: 7, count: ids.count)
            kmap_find_fenced(keys, keyCount, fences, fenceCount, stride, ids, ids.count, &out)
            XCTAssertEqual(out, [-1, -1, -1], "stride \(stride), \(keyCount) keys, \(fenceCount) fences")
        }
        var found = [Int64](repeating: 7, count: ids.count)
        kmap_find_fenced(keys, keys.count, fences, fences.count, 2, ids, ids.count, &found)
        XCTAssertEqual(found, [0, 2, -1])
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

    /// The last merges are cut into pieces; ids repeated across a cut must not be lost
    /// or doubled there.
    func testMergingInPiecesKeepsEveryRepeat() {
        for spread in [3, 50, 1_000_000] {
            var state: UInt64 = UInt64(spread)
            var ids = (0..<300_017).map { _ -> Int64 in
                state ^= state << 13; state ^= state >> 7; state ^= state << 17
                return Int64(state % UInt64(spread))
            }
            let expected = ids.sorted()
            IDSort.sort(&ids)
            XCTAssertEqual(ids, expected, "spread \(spread)")
        }
    }

    /// Where a merge is cut: as many from the left as a 1-piece merge takes first.
    func testTheCutTakesWhatAOnePieceMergeWould() {
        var state: UInt64 = 7
        for _ in 0..<200 {
            func next(_ below: UInt64) -> Int64 {
                state ^= state << 13; state ^= state >> 7; state ^= state << 17
                return Int64(state % below)
            }
            let left = (0..<Int(next(20))).map { _ in next(10) }.sorted()
            let right = (0..<Int(next(20))).map { _ in next(10) }.sorted()
            var both = left + right
            both.withUnsafeMutableBufferPointer { from in
                var l = 0, r = 0
                for count in 0...(left.count + right.count) {
                    let cut = IDSort.split(from, low: 0, middle: left.count, high: left.count + right.count, at: count)
                    XCTAssertEqual(cut, l, "\(left) \(right) at \(count)")
                    if l < left.count && (r == right.count || left[l] <= right[r]) { l += 1 } else { r += 1 }
                }
            }
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

    // MARK: The radix sort

    func testTheRadixSortAgreesWithTheStandardSortOnEveryKindOfID() {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return seed
        }
        // OSM-like ids, ids sharing every byte but 1, the full range with both signs,
        // and the extremes.
        let makers: [() -> Int64] = [
            { Int64(next() % 13_000_000_000) },
            { 4_000_000_000 + Int64(next() % 200) },
            { Int64(bitPattern: next()) },
            { [Int64.min, Int64.max, 0, -1, 1][Int(next() % 5)] }
        ]
        for make in makers {
            for count in [2, 3, 255, 256, 257, 1023, 1024, 1025, 5000, 70_000, 200_001] {
                var ids = (0..<count).map { _ in make() }
                let expected = ids.sorted()
                IDSort.sort(&ids)
                XCTAssertEqual(ids, expected, "\(count) ids")
            }
        }
    }

    func testTheRadixSortLeavesItsAnswerInTheIDsWhateverTheNumberOfPasses() {
        // 1 varying byte is 1 pass, which ends in the scratch and has to be brought back.
        for bytes in 1...8 {
            var ids = (0..<4000).map { i -> Int64 in
                var value: UInt64 = 0
                for byte in 0..<bytes { value |= UInt64((i * (byte + 7) + 13 * byte) & 0xff) << UInt64(byte * 8) }
                return Int64(bitPattern: value)
            }
            let expected = ids.sorted()
            IDSort.sort(&ids)
            XCTAssertEqual(ids, expected, "\(bytes) varying byte(s)")
        }
    }

    func testChunksThatEndInDifferentArraysAreGatheredWhereMostEnded() {
        // 4 chunks of 1000: a chunk of ids under 2^16 varies in 2 bytes and ends in the ids,
        // one of ids past 2^32 in 5 and ends in the scratch. Both majorities, and a tie.
        let size = 1000
        func chunk(low: Bool, _ n: Int) -> [Int64] {
            (0..<size).map { i -> Int64 in
                let spread = Int64((i &* 40_503 &+ n &* 7) & 0xffff)
                return low ? spread : 5_000_000_000 + spread &* 61_001
            }
        }
        for pattern in [[true, true, true, false], [false, false, false, true], [true, false, true, false]] {
            var ids = pattern.enumerated().flatMap { chunk(low: $0.element, $0.offset) }
            var scratch = [Int64](repeating: 0, count: ids.count)
            let original = ids
            let inIDs = IDSort.sortChunks(&ids, of: size, scratch: &scratch)
            let lows = pattern.filter { $0 }.count
            XCTAssertEqual(inIDs, lows * 2 >= pattern.count, "\(pattern): where most ended, a tie in the ids")
            let gathered = inIDs ? ids : scratch
            for (at, _) in pattern.enumerated() {
                let stretch = Array(gathered[at * size..<(at + 1) * size])
                XCTAssertEqual(stretch, original[at * size..<(at + 1) * size].sorted(), "\(pattern) chunk \(at)")
            }
        }
    }

    func testChunksInDifferentArraysStillSortWhole() {
        // The same, through the whole sort past the split threshold.
        for lowShare in [0.3, 0.7] {
            let total = 400_000
            let low = Int(Double(total) * lowShare)
            var ids: [Int64] = []
            ids.reserveCapacity(total)
            for i in 0..<total {
                let value: Int64
                if i < low {
                    value = Int64((i &* 40_503) & 0xffff)
                } else {
                    let spread: Int64 = Int64((i &* 2_654_435_761) % 4_000_000_000)
                    value = 5_000_000_000 + spread
                }
                ids.append(value)
            }
            let expected = ids.sorted()
            IDSort.sort(&ids)
            XCTAssertEqual(ids, expected, "\(lowShare) of the ids in the low chunks")
        }
    }

    func testIDsKmapInventsAndNegativeOnesSortAsTheStandardSortDoes() {
        // Invented ids fill 6 bytes, a negative one all 8: an even number of passes ends in
        // the ids, an odd one in the scratch, and either is the answer.
        for count in [2_000, 70_000, 300_000] {
            var invented = (0..<count).map { i -> Int64 in
                let high: Int64 = (1 << 40) + (Int64(i % 7) << 32)
                return high + Int64((i &* 977) % 100_000)
            }
            var negative = (0..<count).map { -Int64(($0 &* 7_919) % 1_000_000) - 1 }
            let expectedInvented = invented.sorted(), expectedNegative = negative.sorted()
            IDSort.sort(&invented)
            IDSort.sort(&negative)
            XCTAssertEqual(invented, expectedInvented, "\(count) invented")
            XCTAssertEqual(negative, expectedNegative, "\(count) negative")
        }
    }

    func testTheRadixSortSaysWhichArrayHoldsItsAnswer() {
        // 1 varying byte: 1 pass, from the ids into the scratch.
        var ids: [Int64] = [3, 1, 2], scratch: [Int64] = [0, 0, 0]
        let inScratch = ids.withUnsafeMutableBufferPointer { a in
            scratch.withUnsafeMutableBufferPointer { kmap_sort_i64_either(a.baseAddress, $0.baseAddress, 3) }
        }
        XCTAssertEqual(inScratch, 1)
        XCTAssertEqual(scratch, [1, 2, 3])
        // 2 varying bytes: 2 passes, back in the ids.
        ids = [0x0201, 0x0102, 0x0101]
        let inIDs = ids.withUnsafeMutableBufferPointer { a in
            scratch.withUnsafeMutableBufferPointer { kmap_sort_i64_either(a.baseAddress, $0.baseAddress, 3) }
        }
        XCTAssertEqual(inIDs, 0)
        XCTAssertEqual(ids, [0x0101, 0x0102, 0x0201])
    }
}
