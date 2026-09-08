import XCTest
@testable import kmap

/// How many tiles a compiler is given at once.
///
/// The heap is a limit beside the core count: a job holds roughly a gigabyte of live
/// data over a gigabyte floor, so on a many-core machine the heap binds first.
final class CompileJobsTests: XCTestCase {

    func testNeverMoreJobsThanTiles() {
        XCTAssertEqual(Machine.compileJobs(tiles: 3, heapGB: 64, nodesPerTile: 1_200_000), 3)
        XCTAssertEqual(Machine.compileJobs(tiles: 1, heapGB: 64, nodesPerTile: 1_200_000), 1)
    }

    /// A machine with far more threads than gigabytes of heap.
    func testAHeapTooSmallForTheCoresBindsFirst() {
        let jobs = Machine.compileJobs(tiles: 64, heapGB: 4, nodesPerTile: 1_200_000)
        XCTAssertEqual(jobs, min(3, Machine.cores),
                       "four gigabytes of heap feeds three jobs over the floor")
    }

    /// Twice the nodes in a tile is twice the tile in memory, so half as many at once.
    func testABiggerTileCeilingMeansFewerAtOnce() {
        let small = Machine.compileJobs(tiles: 64, heapGB: 9, nodesPerTile: 1_200_000)
        let large = Machine.compileJobs(tiles: 64, heapGB: 9, nodesPerTile: 2_400_000)
        XCTAssertGreaterThan(small, large)
        XCTAssertEqual(large, min(4, Machine.cores))
    }

    /// Below the reference size the floor stops being the tile and becomes the compiler
    /// itself, so a smaller tile buys no extra jobs.
    func testASmallerTileDoesNotBuyMoreThanAGigabyteEach() {
        XCTAssertEqual(Machine.compileJobs(tiles: 64, heapGB: 5, nodesPerTile: 100_000),
                       min(4, Machine.cores))
    }

    func testNeverZero() {
        XCTAssertEqual(Machine.compileJobs(tiles: 0, heapGB: 0, nodesPerTile: 0), 1)
        XCTAssertEqual(Machine.compileJobs(tiles: 14, heapGB: 1, nodesPerTile: 9_000_000), 1)
    }

    /// On whatever machine the suite runs, the answer stays between one and the core count.
    func testItFitsTheMachineItRunsOn() {
        let jobs = Machine.compileJobs(tiles: 14, heapGB: 24, nodesPerTile: 1_200_000)
        XCTAssertGreaterThanOrEqual(jobs, 1)
        XCTAssertLessThanOrEqual(jobs, Machine.cores)
    }
}
