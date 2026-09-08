import XCTest
@testable import kmap

/// The merge that drops a node repeated between overlapping extracts.
///
/// Correct only while both premises hold: the table knows where each file's stretch ends,
/// and every stretch ascends strictly. A file that breaks either raises the fallback signal.
final class FileMergeDedupTests: XCTestCase {

    private func table(files: [[Int64]]) -> TileSplitter.NodeAreas {
        let nodes = TileSplitter.NodeAreas(expecting: files.reduce(0) { $0 + $1.count })
        for ids in files {
            nodes.append(ids: ids, values: ids.map { _ in 0 })
            nodes.markFileEnd()
        }
        return nodes
    }

    func testACursorFindsExactlyTheEarlierFilesNodes() {
        let nodes = table(files: [[10, 20, 30, 40], [15, 20, 35, 40, 50]])
        var earlier = nodes.fileCursors(before: 1)
        XCTAssertEqual(earlier.count, 1)

        // The second file's ids, asked in their own ascending order.
        XCTAssertFalse(earlier[0].contains(15))
        XCTAssertTrue(earlier[0].contains(20), "20 is in the first file")
        XCTAssertFalse(earlier[0].contains(35))
        XCTAssertTrue(earlier[0].contains(40))
        XCTAssertFalse(earlier[0].contains(50), "past the stretch, and must stay out")
    }

    func testTheThirdFileSeesBothEarlierOnes() {
        let nodes = table(files: [[10, 20], [30, 40], [10, 25, 40, 60]])
        var earlier = nodes.fileCursors(before: 2)
        XCTAssertEqual(earlier.count, 2)

        func repeated(_ id: Int64) -> Bool {
            var hit = false
            for i in earlier.indices where earlier[i].contains(id) { hit = true }
            return hit
        }
        XCTAssertTrue(repeated(10), "in the first file")
        XCTAssertFalse(repeated(25))
        XCTAssertTrue(repeated(40), "in the second file")
        XCTAssertFalse(repeated(60))
    }

    /// A file whose ids do not ascend must be reported, so the write pass can fall back to
    /// the unconditional Set.
    func testAnUnsortedFileRaisesTheFallbackSignal() {
        let sorted = table(files: [[10, 20, 30], [15, 25, 35]])
        XCTAssertFalse(sorted.filesInterleave)
        XCTAssertEqual(sorted.fileEnds, [3, 6])

        let unsorted = table(files: [[10, 20, 30], [25, 15, 35]])
        XCTAssertTrue(unsorted.filesInterleave)
    }

    /// Equal neighbours count as non-ascending: a repeat within one file would slip past
    /// cursors that only look at earlier files.
    func testARepeatedIdWithinOneFileRaisesItToo() {
        let nodes = table(files: [[10, 20, 20, 30]])
        XCTAssertTrue(nodes.filesInterleave)
    }

    func testAnEmptyFileIsAnEmptyStretchAndNothingMore() {
        let nodes = table(files: [[10, 20], [], [15, 20]])
        XCTAssertFalse(nodes.filesInterleave)
        XCTAssertEqual(nodes.fileEnds, [2, 2, 4])
        var earlier = nodes.fileCursors(before: 2)
        XCTAssertEqual(earlier.count, 2)
        XCTAssertFalse(earlier[1].contains(15), "the empty stretch holds nothing")
        XCTAssertTrue(earlier[0].contains(20))
    }
}
