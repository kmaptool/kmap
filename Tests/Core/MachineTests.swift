import XCTest
@testable import kmap

/// What the build asks the machine about itself.
///
/// Each count sizes a parallel pass, so a zero or a negative is a `concurrentPerform`
/// with a nonsense iteration count: the floors matter more than the values.
final class MachineTests: XCTestCase {

    func testEveryCountIsAtLeastOne() {
        XCTAssertGreaterThanOrEqual(Machine.cores, 1)
        XCTAssertGreaterThanOrEqual(Machine.fastCores, 1)
        XCTAssertGreaterThanOrEqual(Machine.readers, 1)
        XCTAssertGreaterThanOrEqual(Machine.workers, 1)
    }

    func testTheFastCoresAreASubsetOfTheCores() {
        // Under a CPU quota a performance-core count above the allowed cores would
        // oversubscribe.
        XCTAssertLessThanOrEqual(Machine.fastCores, Machine.cores)
    }

    func testReadersAreCappedButWorkersOnlyStepBack() {
        // Readers are capped by the rate the file can be fed at; workers leave room for
        // the reader and the writer either side of them.
        XCTAssertLessThanOrEqual(Machine.readers, 16)
        XCTAssertLessThanOrEqual(Machine.readers, Machine.cores)
        XCTAssertLessThanOrEqual(Machine.workers, Machine.cores)
        if Machine.cores > 3 { XCTAssertEqual(Machine.workers, Machine.cores - 2) }
    }

    func testTheAnswerDoesNotChangeBetweenTwoAsks() {
        // Read once per pass to size arrays indexed by lane; a count that drifted
        // between the sizing and the loop would run off the end.
        XCTAssertEqual(Machine.fastCores, Machine.fastCores)
        XCTAssertEqual(Machine.cores, Machine.cores)
    }
}
