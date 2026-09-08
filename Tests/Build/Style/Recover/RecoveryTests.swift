import XCTest
@testable import kmap

/// The pure parts of style recovery: the grid, the matcher, the rule book.
final class RecoveryTests: XCTestCase {

    // MARK: The grid

    func testTheGridIsTheFormatsOwn() {
        // 360° over 24 bits, the constant the format is built on.
        XCTAssertEqual(GarminGrid.unit(0), 0)
        XCTAssertEqual(GarminGrid.unit(180), 1 << 23)
        XCTAssertEqual(GarminGrid.unit(-180), -(1 << 23))
        // Neighbouring grid steps stay distinct cells.
        let step = 360.0 / Double(1 << 24)
        XCTAssertNotEqual(GarminGrid.cell(lat: 44, lon: 34),
                          GarminGrid.cell(lat: 44 + step, lon: 34))
    }

    func testGramsNeedThreeVertices() {
        XCTAssertTrue(GarminGrid.grams(of: [1, 2]).isEmpty)
        XCTAssertEqual(GarminGrid.grams(of: [1, 2, 3, 4]).count, 2)
        // Order matters: a reversed chain has different grams.
        XCTAssertNotEqual(GarminGrid.grams(of: [1, 2, 3]), GarminGrid.grams(of: [3, 2, 1]))
    }

    // MARK: The matcher's run rule

    func testARunIsCountedInEitherDirection() {
        let way: [UInt64] = [10, 11, 12, 13, 14, 15]
        XCTAssertEqual(ElementMatcher.longestRun(of: [11, 12, 13], in: way), 3)
        XCTAssertEqual(ElementMatcher.longestRun(of: [13, 12, 11], in: way), 3,
                       "mkgmap writes a way whichever way round suits it")
        XCTAssertEqual(ElementMatcher.longestRun(of: [11, 99, 13], in: way), 1)
    }

    func testTheThresholdScalesWithTheElement() {
        XCTAssertEqual(ElementMatcher.threshold(4), 4, "never below the minimum run")
        XCTAssertEqual(ElementMatcher.threshold(20), 10, "half of a long element")
    }

    // MARK: The rule book

    func testLeadingPairsComeFromAlternativesOnly() {
        XCTAssertEqual(DefaultRuleBook.leadingPairs(of: "landuse=forest | landuse=wood & foo=bar"),
                       ["landuse=forest", "landuse=wood"])
        // Narrowing terms after & are not meanings; negations never are. A bare
        // `key=*` is a family rule — every value of the key — and is indexed as one.
        XCTAssertEqual(DefaultRuleBook.leadingPairs(of: "highway=* & bicycle=yes"),
                       ["highway=*"])
        XCTAssertEqual(DefaultRuleBook.leadingPairs(of: "highway=primar* & foo=bar"), [])
        XCTAssertEqual(DefaultRuleBook.leadingPairs(of: "mkgmap:repair=yes"), [])
    }

    func testALineRewritesKeepingItsWidth() throws {
        let line = try XCTUnwrap(DefaultRuleBook.Line(
            file: "points", text: "place=hamlet & name=* [0x0b00 resolution 24]"))
        XCTAssertTrue(line.emits(0x0b00))
        XCTAssertEqual(line.rewritten(to: 0x2a00),
                       "place=hamlet & name=* [0x2a00 resolution 24]",
                       "the token keeps its four digits")
        XCTAssertEqual(line.rewritten(to: 0x900),
                       "place=hamlet & name=* [0x0900 resolution 24]",
                       "a shorter code is padded, not shrunk")
    }

    // MARK: Tallies from several cores

    /// The match is split across cores and each piece keeps its own tally. Folding them
    /// gives what one core would count: counts add, and sources keyed by OSM id merge.
    func testTalliesFromTwoCoresAddUpToOne() {
        func part(_ kind: ElementDumper.Kind, _ type: Int, elements: Int, unmatched: Int,
                  sources: [Int64: [String: String]]) -> Evidence.ForCode {
            var code = Evidence.ForCode(kind: kind, type: type)
            code.elements = elements
            code.unmatched = unmatched
            code.sources = sources
            return code
        }
        var whole = Evidence(codes: ["L10206": part(
            .line, 0x10206, elements: 6, unmatched: 2,
            sources: [11: ["highway": "residential"]])])
        whole.merge(Evidence(codes: [
            "L10206": part(.line, 0x10206, elements: 4, unmatched: 1,
                           sources: [11: ["highway": "residential"],
                                     12: ["highway": "service"]]),
            "A52": part(.area, 0x52, elements: 3, unmatched: 0,
                        sources: [13: ["landuse": "forest"]]),
        ]))
        XCTAssertEqual(whole.codes["L10206"]?.elements, 10)
        XCTAssertEqual(whole.codes["L10206"]?.unmatched, 3)
        XCTAssertEqual(whole.codes["L10206"]?.sources.count, 2, "way 11 was seen by both")
        XCTAssertEqual(whole.codes["A52"]?.elements, 3, "a code only one piece saw")
    }

    // MARK: The dumper's output format

    /// The dump is binary, in the units mkgmap read: a kind byte, a type, a vertex count
    /// and that many pairs of 24-bit map units, little-endian.
    func testTheDumpParses() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("dump-\(UUID().uuidString.prefix(6)).bin")
        defer { try? FileManager.default.removeItem(at: file) }

        var bytes: [UInt8] = []
        func put(_ value: Int32) {
            for shift in stride(from: 0, to: 32, by: 8) {
                bytes.append(UInt8(truncatingIfNeeded: value >> Int32(shift)))
            }
        }
        func element(_ kind: UInt8, _ type: Int32, _ points: [(Double, Double)]) {
            bytes.append(kind)
            put(type)
            put(Int32(points.count))
            for (lat, lon) in points {
                put(GarminGrid.unit(lat))
                put(GarminGrid.unit(lon))
            }
        }
        element(1, 0x10804, [(54.4644210, 19.6596690), (54.4644000, 19.6599050),
                             (54.4638420, 19.6596910)])
        element(2, 0x52, [(54.4748930, 19.6929930), (54.4748280, 19.6918990)])
        element(0, 0x6417, [(54.4533060, 19.9612780)])
        try Data(bytes).write(to: file)

        let dump = try ElementDumper.parse(file)
        XCTAssertEqual(dump.count, 3)
        XCTAssertEqual(dump.elements[0].kind, .line)
        XCTAssertEqual(dump.elements[0].type, 0x10804)
        XCTAssertEqual(dump.chain(0).count, 3)
        XCTAssertEqual(dump.chain(0).first,
                       GarminGrid.cell(lat: 54.4644210, lon: 19.6596690),
                       "the cell a coordinate lands on is the same one the ground uses")
        XCTAssertEqual(dump.elements[2].kind, .point)
        XCTAssertEqual(dump.chain(2).count, 1)
    }

    /// Half a coordinate at the end of the file is a truncated dump, not an element.
    func testAHalfWrittenDumpStopsWhereItStops() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("dump-\(UUID().uuidString.prefix(6)).bin")
        defer { try? FileManager.default.removeItem(at: file) }
        var bytes: [UInt8] = [1]
        bytes += [0x04, 0x08, 0x01, 0x00]   // type
        bytes += [0x03, 0x00, 0x00, 0x00]   // three vertices promised
        bytes += [UInt8](repeating: 0x11, count: 8)   // one delivered
        try Data(bytes).write(to: file)
        XCTAssertEqual(try ElementDumper.parse(file).count, 0)
    }
}
