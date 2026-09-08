import XCTest
@testable import kmap

/// The single-byte Windows code pages, which decide whether a Cyrillic map is a Cyrillic
/// map. The last tests decode and encode every byte of every page both ways and require
/// `CodePage` to agree with Foundation; they run on Apple platforms only, since elsewhere
/// there is no second implementation to compare against. The rest run everywhere.
final class CodePageTests: XCTestCase {

    /// A six-letter Cyrillic name as Windows-1251.
    private let moscow1251: [UInt8] = [0xCC, 0xEE, 0xF1, 0xEA, 0xE2, 0xE0]

    // MARK: Decoding

    func testCyrillicDecodesAsCyrillic() {
        XCTAssertEqual(CodePage.decode(moscow1251, codePage: 1251), "Москва")
    }

    func testTheSameBytesUnderTheWrongPageAreTheSymptomThatGivesItAway() {
        // Not an error: a wrong page yields text that reads as a corrupt file rather
        // than as a wrong guess.
        XCTAssertEqual(CodePage.decode(moscow1251, codePage: 1252), "Ìîñêâà")
    }

    func testAsciiIsTheSameInEveryPage() {
        let ascii = (0..<0x80).map { UInt8($0) }
        let expected = String(String.UnicodeScalarView(ascii.map { UnicodeScalar($0) }))
        for page in CodePage.supported {
            XCTAssertEqual(CodePage.decode(ascii, codePage: page), expected, "in \(page)")
        }
    }

    func testTheCharactersEachPageExistsFor() {
        // One letter per page that no other page in the set has at that byte.
        XCTAssertEqual(CodePage.decode([0xE8], codePage: 1250), "č")
        XCTAssertEqual(CodePage.decode([0xE8], codePage: 1251), "и")
        XCTAssertEqual(CodePage.decode([0xE8], codePage: 1252), "è")
        XCTAssertEqual(CodePage.decode([0xE8], codePage: 1253), "θ")
        XCTAssertEqual(CodePage.decode([0xE8], codePage: 1254), "è")
        // Turkish 1254 differs from 1252 in exactly six places; 0xDD is one of them.
        XCTAssertEqual(CodePage.decode([0xDD], codePage: 1254), "İ")
        XCTAssertEqual(CodePage.decode([0xDD], codePage: 1252), "Ý")
    }

    func testTheEuroSignIsWhereEachPagePutsItAndNotWhereItIsAssumedToBe() {
        // 0x80 in four of the five, and 0x88 in 1251, which puts Ђ at 0x80 instead.
        for page in [1250, 1252, 1253, 1254] {
            XCTAssertEqual(CodePage.decode([0x80], codePage: page), "€", "in \(page)")
        }
        XCTAssertEqual(CodePage.decode([0x88], codePage: 1251), "€")
        XCTAssertEqual(CodePage.decode([0x80], codePage: 1251), "Ђ")
    }

    func testAByteWithNoCharacterInThePageRefusesTheWholeString() {
        // 0x98 is a hole in 1251. Decoding it to a replacement character would report
        // success on a name that is wrong.
        XCTAssertNil(CodePage.decode([0x41, 0x98, 0x42], codePage: 1251))
        XCTAssertNil(CodePage.decode([0x81], codePage: 1252))
        XCTAssertNil(CodePage.decode([0xFF], codePage: 1253))
    }

    func testTheLenientDecodeFallsBackToLatinOneRatherThanToNothing() {
        // A label that cannot be decoded is still worth showing.
        XCTAssertEqual(CodePage.decodeLenient([0x41, 0x98, 0x42], codePage: 1251), "A\u{98}B")
        XCTAssertEqual(CodePage.decodeLenient(moscow1251, codePage: 1251), "Москва")
    }

    func testAPageWithNoTableIsReadAsLatinOne() {
        XCTAssertEqual(CodePage.decode(moscow1251, codePage: 0), "Ìîñêâà")
        XCTAssertEqual(CodePage.decode(moscow1251, codePage: 932), "Ìîñêâà")
    }

    func testUtf8IsAPageToo() {
        XCTAssertEqual(CodePage.decode(Array("Москва".utf8), codePage: CodePage.utf8), "Москва")
        XCTAssertNil(CodePage.decode([0xC3, 0x28], codePage: CodePage.utf8), "not valid UTF-8")
    }

    func testAnEmptyRunOfBytesIsAnEmptyString() {
        for page in CodePage.supported + [0, CodePage.utf8] {
            XCTAssertEqual(CodePage.decode([], codePage: page), "", "in \(page)")
        }
    }

    // MARK: Encoding

    func testEveryPageRoundTripsEveryByteItDefines() {
        for page in CodePage.supported {
            for byte in 0...255 {
                guard let text = CodePage.decode([UInt8(byte)], codePage: page) else { continue }
                XCTAssertEqual(CodePage.encode(text, codePage: page), [UInt8(byte)],
                               "byte 0x\(String(byte, radix: 16)) in \(page)")
            }
        }
    }

    func testACharacterThePageCannotHoldIsRefusedOrMarked() {
        XCTAssertNil(CodePage.encode("Москва", codePage: 1252))
        XCTAssertEqual(CodePage.encode("Москва", codePage: 1252, lossy: true),
                       Array(repeating: 0x3F, count: 6))
        XCTAssertEqual(CodePage.encode("a☃b", codePage: 1251, lossy: true), [0x61, 0x3F, 0x62])
    }

    func testAccentsWrittenAsTwoScalarsStillFitAPageThatHasThem() {
        // An accented letter is often written as base + combining mark, which is not in
        // 1252 as written; the encoder composes first.
        let decomposed = "Cre\u{301}che"
        XCTAssertEqual(CodePage.encode(decomposed, codePage: 1252),
                       [0x43, 0x72, 0xE9, 0x63, 0x68, 0x65])
    }

    func testWhetherAPageCanHoldANameIsAskableWithoutEncodingIt() {
        XCTAssertTrue(CodePage.canHold("Wien", codePage: 1252))
        XCTAssertTrue(CodePage.canHold("Москва", codePage: 1251))
        XCTAssertFalse(CodePage.canHold("Москва", codePage: 1252))
        XCTAssertTrue(CodePage.canHold("Москва", codePage: CodePage.utf8))
    }

    func testUtf8EncodesAsUtf8() {
        XCTAssertEqual(CodePage.encode("Москва", codePage: CodePage.utf8), Array("Москва".utf8))
    }

    // MARK: Against Foundation, where there is a Foundation to ask

    #if canImport(Darwin)
    func testEveryByteOfEveryPageDecodesTheWayFoundationDoes() {
        // 1280 comparisons: every byte of every page, against Foundation's own tables.
        let pages: [(Int, String.Encoding)] = [
            (1250, .windowsCP1250), (1251, .windowsCP1251), (1252, .windowsCP1252),
            (1253, .windowsCP1253), (1254, .windowsCP1254)
        ]
        for (page, encoding) in pages {
            for byte in 0...255 {
                let bytes = [UInt8(byte)]
                XCTAssertEqual(CodePage.decode(bytes, codePage: page),
                               String(bytes: bytes, encoding: encoding),
                               "byte 0x\(String(format: "%02X", byte)) in \(page)")
            }
        }
    }

    func testEveryCharacterOfEveryPageEncodesTheWayFoundationDoes() {
        let pages: [(Int, String.Encoding)] = [
            (1250, .windowsCP1250), (1251, .windowsCP1251), (1252, .windowsCP1252),
            (1253, .windowsCP1253), (1254, .windowsCP1254)
        ]
        for (page, encoding) in pages {
            for byte in 0...255 {
                guard let text = String(bytes: [UInt8(byte)], encoding: encoding) else { continue }
                let theirs = text.data(using: encoding).map(Array.init)
                XCTAssertEqual(CodePage.encode(text, codePage: page), theirs,
                               "U+\(String(format: "%04X", text.unicodeScalars.first!.value)) in \(page)")
            }
        }
    }

    func testRealNamesEncodeTheWayFoundationEncodesThem() {
        let names = ["Москва", "Симферополь", "Ялта", "Севастополь",
                     "Wien", "Zürich", "Kraków", "Ostrów Wielkopolski",
                     "İstanbul", "Şişli", "Αθήνα", "Θεσσαλονίκη",
                     "Straße", "Œuvre", "naïve", "señor", "—", "€5"]
        let pages: [(Int, String.Encoding)] = [
            (1250, .windowsCP1250), (1251, .windowsCP1251), (1252, .windowsCP1252),
            (1253, .windowsCP1253), (1254, .windowsCP1254)
        ]
        for (page, encoding) in pages {
            for name in names {
                XCTAssertEqual(CodePage.encode(name, codePage: page),
                               name.data(using: encoding).map(Array.init),
                               "\"\(name)\" strict in \(page)")
                XCTAssertEqual(CodePage.encode(name, codePage: page, lossy: true),
                               name.data(using: encoding, allowLossyConversion: true)
                                   .map(Array.init),
                               "\"\(name)\" lossy in \(page)")
            }
        }
    }
    #endif
}
