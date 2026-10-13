import XCTest

@testable import kmap

/// A plain condition's terms, read once and judged against the tags of a source.
final class DefaultRuleLineTermTests: XCTestCase {
    private typealias Term = DefaultRuleBook.Line.Term

    func testEachKindOfTermIsJudgedAsMkgmapJudgesIt() {
        let tags = ["highway": "path", "ele": "1200 m"]
        XCTAssertEqual(Term("highway=path").holds(for: tags), true)
        XCTAssertEqual(Term("highway = 'path'").holds(for: tags), true)
        XCTAssertEqual(Term("highway=*").holds(for: tags), true)
        XCTAssertEqual(Term("bridge!=*").holds(for: tags), true)
        XCTAssertEqual(Term("highway!=track").holds(for: tags), true)
        XCTAssertEqual(Term("ele>=1000").holds(for: tags), true)
        XCTAssertEqual(Term("ele<1000").holds(for: tags), false)
        XCTAssertEqual(Term("width>2").holds(for: tags), false, "a value with no number fails")
    }

    func testATermKmapCannotJudgeSaysSo() {
        XCTAssertNil(Term("mkgmap:admin_level2=*").holds(for: [:]))
        XCTAssertNil(Term("ele>high").holds(for: ["ele": "3"]))
        XCTAssertNil(Term("no operator here").holds(for: [:]))
    }

    /// The terms decide in their written order: a failed term before one kmap cannot judge
    /// settles the rule, one after it does not.
    func testTheTermsDecideInTheOrderTheyAreWritten() throws {
        let failsFirst = try XCTUnwrap(DefaultRuleBook.Line(file: "lines", text: "highway=track & mkgmap:x=1 [0x0a]"))
        let unknownFirst = try XCTUnwrap(DefaultRuleBook.Line(file: "lines", text: "mkgmap:x=1 & highway=track [0x0a]"))
        let tags = ["highway": "path"]
        XCTAssertEqual(failsFirst.holds(for: tags), false)
        XCTAssertNil(unknownFirst.holds(for: tags))
        XCTAssertNil(try XCTUnwrap(DefaultRuleBook.Line(file: "lines", text: "(a=b | c=d) [0x0a]")).holds(for: tags))
    }

    func testTheCodeIsReadOnce() throws {
        let line = try XCTUnwrap(DefaultRuleBook.Line(file: "points", text: "amenity=fuel [0x2f01 resolution 24]"))
        XCTAssertTrue(line.emits(0x2f01))
        XCTAssertFalse(line.emits(0x2f))
        XCTAssertEqual(line.code, "2f01")
    }
}
