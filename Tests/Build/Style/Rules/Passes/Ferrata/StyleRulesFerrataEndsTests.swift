import XCTest

@testable import kmap

/// An icon at each end of a via ferrata, only where the TYP has one.
final class StyleRulesFerrataEndsTests: XCTestCase {
    /// The end icon goes at whatever resolution a zoom plan gave it.
    func testTheEndIconIsDroppedAtAnyResolution() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ends-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let points = dir.appendingPathComponent("points")
        try "kmap:ferrata_end=yes [0x660a resolution 23 continue]\nnatural=peak [0x6616 resolution 22]\n"
            .write(to: points, atomically: true, encoding: .utf8)
        try StyleCatalog.dropFerrataEnds(in: dir)
        XCTAssertEqual(try String(contentsOf: points, encoding: .utf8), "natural=peak [0x6616 resolution 22]\n")
        // Aimed at their climber by hand: the person's choice stays.
        let aimed = "kmap:ferrata_end=yes [0x2c0e resolution 22 continue]  \(RuleReassignment.mark)0x660a\n"
        try aimed.write(to: points, atomically: true, encoding: .utf8)
        try StyleCatalog.dropFerrataEnds(in: dir)
        XCTAssertEqual(try String(contentsOf: points, encoding: .utf8), aimed)
    }
}
