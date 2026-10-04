import XCTest

@testable import kmap

/// The string table of a block being written: every tag of every element is looked up
/// here, and the order of its words is the bytes of the file.
final class StringTableTests: XCTestCase {
    func testWordsAreNumberedInTheOrderFirstAsked() {
        var table = StringTable()
        XCTAssertEqual(table.index("highway"), 1)
        XCTAssertEqual(table.index("residential"), 2)
        XCTAssertEqual(table.index("highway"), 1)
        XCTAssertEqual(table.index("name"), 3)
        XCTAssertEqual(table.words, ["", "highway", "residential", "name"])
    }

    func testAnEmptyTextTakesAnIndexOfItsOwn() {
        // Index 0 is the format's, never handed out: an empty role is a word like any other.
        var table = StringTable()
        XCTAssertEqual(table.index("outer"), 1)
        XCTAssertEqual(table.index(""), 2)
        XCTAssertEqual(table.index(""), 2)
        XCTAssertEqual(table.words, ["", "outer", ""])
    }

    func testTwoSpellingsOfTheSameTextShareTheFirstOnesIndex() {
        // Precomposed and decomposed: equal to the standard library, and so 1 word.
        var table = StringTable()
        let composed = "caf\u{e9}", decomposed = "cafe\u{301}"
        XCTAssertEqual(composed, decomposed)
        XCTAssertEqual(table.index(composed), 1)
        XCTAssertEqual(table.index(decomposed), 1)
        XCTAssertEqual(Array(table.words[1].utf8), Array(composed.utf8), "the first spelling is the one written")
    }

    func testCyrillicAndASCIIWordsThatLookAlikeStayApart() {
        var table = StringTable()
        XCTAssertEqual(table.index("a"), 1)
        XCTAssertEqual(table.index("\u{430}"), 2)
        XCTAssertEqual(table.index("A"), 3)
        XCTAssertEqual(table.index("a "), 4)
    }

    func testTheTableAgreesWithADictionaryOnThousandsOfWords() {
        var table = StringTable()
        var seen: [String: Int32] = [:]
        var words = [""]
        var seed: UInt64 = 88_172_645_463_325_252
        func next() -> UInt64 {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return seed
        }
        let alphabet = Array("abcdeйцукенгшщ_:0123456789 é")
        for _ in 0..<30_000 {
            let length = Int(next() % 6)
            let word = String((0..<length).map { _ in alphabet[Int(next() % UInt64(alphabet.count))] })
            let expected: Int32
            if let known = seen[word] {
                expected = known
            } else {
                words.append(word)
                expected = Int32(words.count - 1)
                seen[word] = expected
            }
            XCTAssertEqual(table.index(word), expected, "'\(word)'")
        }
        XCTAssertEqual(table.words, words)
    }
}
