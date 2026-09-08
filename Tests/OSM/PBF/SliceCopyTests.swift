import XCTest
@testable import kmap

/// Copying a reader's slice out of the buffer it was handed in.
///
/// Where a slice covers its whole buffer, the standard library hands the buffer over
/// rather than copying it, and the copy then carries the buffer's capacity.
final class SliceCopyTests: XCTestCase {

    /// The shape a reader hands over: one scratch array, filled and cleared per object,
    /// keeping its capacity so it need not grow again.
    private func scratch(longest: Int, then short: Int) -> ArraySlice<Int64> {
        var buffer: [Int64] = []
        buffer.append(contentsOf: (0..<longest).map(Int64.init))
        buffer.removeAll(keepingCapacity: true)
        buffer.append(contentsOf: (0..<short).map(Int64.init))
        return buffer[...]
    }

    func testACopyHoldsTheSameElements() {
        let slice = scratch(longest: 2000, then: 43)
        XCTAssertEqual(slice.exactly, Array(slice))
        XCTAssertEqual(slice.exactly.count, 43)
    }

    func testACopyDoesNotInheritTheBuffersRoom() {
        var buffer: [Int64] = []
        buffer.reserveCapacity(4096)
        buffer.append(contentsOf: (0..<40).map(Int64.init))
        let copy = buffer[...].exactly
        // Grown once more, so the copy is forced to stand on its own.
        buffer.append(99)
        XCTAssertEqual(copy.count, 40)
        XCTAssertLessThan(copy.capacity, 128, "room for 40, not for the buffer's 4096")
    }

    func testAnEmptySliceCopiesToAnEmptyArray() {
        let empty: [Int64] = []
        XCTAssertTrue(empty[...].exactly.isEmpty)
    }

    func testAPartialSliceKeepsOnlyItsOwnRange() {
        let buffer = Array<Int64>(0..<100)
        XCTAssertEqual(buffer[10..<15].exactly, [10, 11, 12, 13, 14])
    }
}
