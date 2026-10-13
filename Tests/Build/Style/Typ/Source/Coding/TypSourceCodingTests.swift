import XCTest

@testable import kmap

/// Reading and writing a TYP source in its code page: what mkgmap reads, kmap reads alike.
final class TypSourceCodingTests: XCTestCase {
    /// TYPViewer saves in the code page the file names: read as mkgmap reads it.
    func testATextTYPIsReadInItsCodePageWhereItIsNotUTF8() {
        var bytes = Array("[_id]\nCodePage=1251\n[end]\n[_point]\nType=0x2f00\nString=0x04,".utf8)
        bytes += CodePage.encode("Родник", codePage: 1251) ?? []
        bytes += Array("\n[end]\n".utf8)
        let text = TypSource.decodeText(bytes)
        XCTAssertTrue(text.contains("Родник"))
        XCTAssertEqual(TypSource.decodeText([0xEF, 0xBB, 0xBF] + Array("Type=0x01".utf8)), "Type=0x01")
        // A coding line naming a code page decides before any CodePage line.
        let coded =
            Array("; -*- coding: cp1251 -*-\nCodePage=1252\nString=0x04,".utf8)
            + (CodePage.encode("Родник", codePage: 1251) ?? [])
        XCTAssertTrue(TypSource.decodeText(coded).contains("Родник"))
    }

    /// Written back as UTF-8, it says so first, or mkgmap reads it by its CodePage line.
    func testWrittenBackTheTextSaysItIsUTF8() {
        let plain = "[_id]\nCodePage=1251\n[end]"
        XCTAssertTrue(TypSource.declaringUTF8(plain).hasPrefix(TypSource.codingLine + "\n[_id]"))
        let already = TypSource.codingLine + "\n" + plain
        XCTAssertEqual(TypSource.declaringUTF8(already), already)
        let other = "; -*- coding: cp1251 -*-\r\n" + "[_id]\r\n[end]"
        XCTAssertEqual(TypSource.declaringUTF8(other), TypSource.codingLine + "\r\n[_id]\r\n[end]")
    }

    func testAByteThePageLeavesUndefinedSpoilsOnlyItself() {
        // 0x98 has no character in cp1251; the Cyrillic around it is still Cyrillic.
        let bytes: [UInt8] = Array("CodePage=1251\nString=0x19,".utf8) + [0xCB, 0xE5, 0xF1, 0x98]
        let text = TypSource.decodeText(bytes)
        XCTAssertTrue(text.hasSuffix("Лес\u{98}"), text)
    }

    func testATextInAPageKmapCannotReadGoesBackByteForByte() {
        // cp1257, the Baltic page, which kmap has no table for.
        let bytes: [UInt8] =
            Array("[_id]\r\nCodePage=1257\r\n[end]\r\n[_polygon]\r\nType=0x01\r\nString=0x04,".utf8)
            + [0xC1, 0xE0, 0xEB, 0xF8] + Array("\r\n[end]\r\n".utf8)
        let read = TypSource.decoding(bytes)
        XCTAssertTrue(read.byteForByte)
        XCTAssertEqual([UInt8](TypSource.bytesToWrite(read.text, byteForByte: true)), bytes)
        XCTAssertEqual(
            [UInt8](TypSource.bytesToWrite(read.text, declaring: true, byteForByte: true)),
            bytes,
            "an import keeps it as it came"
        )
        // An addition keeps the rest in its bytes, and what the page cannot hold is `?`.
        let added = read.text + "String=0x19,\u{41B}\r\n"
        let written = [UInt8](TypSource.bytesToWrite(added, declaring: true, byteForByte: true))
        XCTAssertEqual(Array(written.prefix(bytes.count)), bytes)
        XCTAssertEqual(Array(written.suffix(3)), Array("?\r\n".utf8))
    }

    /// UTF-8 that names a page kmap cannot read was read as UTF-8, and is written so: kept
    /// in single bytes it would change, and mkgmap would read it by the page.
    func testUTF8NamingAnUntabledPageIsStillUTF8() {
        let bytes = Array("[_id]\nCodePage=1257\n[end]\nString=0x04,P\u{E4}rnu\n".utf8)
        let read = TypSource.decoding(bytes)
        XCTAssertFalse(read.byteForByte)
        let written = String(decoding: TypSource.bytesToWrite(read.text, byteForByte: read.byteForByte), as: UTF8.self)
        XCTAssertTrue(written.hasPrefix(TypSource.codingLine), written)
        XCTAssertTrue(written.contains("P\u{E4}rnu"))
    }

    /// A coding line naming a charset kmap has no table for keeps the file as it came.
    func testACharsetKmapCannotReadKeepsItsBytesAndItsLine() {
        let bytes: [UInt8] = Array("; -*- coding: koi8-r -*-\nString=0x19,".utf8) + [0xEC, 0xC5, 0xD3, 0x0A]
        let read = TypSource.decoding(bytes)
        XCTAssertTrue(read.byteForByte)
        XCTAssertEqual([UInt8](TypSource.bytesToWrite(read.text, declaring: true, byteForByte: true)), bytes)
    }

    func testATextKmapCanReadIsStillWrittenAsUTF8() {
        let read = TypSource.decoding(Array("CodePage=1251\nString=0x19,".utf8) + [0xCB, 0xE5, 0xF1])
        XCTAssertFalse(read.byteForByte)
        let written = String(decoding: TypSource.bytesToWrite(read.text), as: UTF8.self)
        XCTAssertTrue(written.contains("\u{41B}\u{435}\u{441}"))
        XCTAssertTrue(written.lowercased().contains("coding: utf-8"), written)
        // Said to be UTF-8 already: no page to keep.
        let said = Array("; -*- coding: utf-8 -*-\nCodePage=1257\nString=0x04,\u{E9}".utf8)
        XCTAssertFalse(TypSource.decoding(said).byteForByte)
        XCTAssertFalse(
            TypSource.decoding(Array("CodePage=1257\nString=0x04,plain".utf8)).byteForByte,
            "ASCII reads alike anywhere"
        )
    }

    /// A CodePage line with a note behind it reads alike both ways: the text is decoded
    /// in the page the parse reports.
    func testACodePageWithANoteBehindItReadsAlikeBothWays() {
        var bytes = Array("[_id]\nCodePage=1251 ; cyrillic\n[end]\n[_point]\nType=0x2f\nString=0x00,".utf8)
        bytes += [0xE9]
        bytes += Array("\n[end]\n".utf8)
        let text = TypSource.decoding(bytes).text
        XCTAssertEqual(TypSource.parse(text).codePage, 1251)
        XCTAssertEqual(TypSource.parse(text).section(.point, 0x2f00)?.labels.first?.text, "\u{0439}")
    }

    /// mkgmap's charset probe takes the first `CodePage=` line for a charset: a note behind
    /// the number, or 0, fails it, unless a coding line came first.
    func testACodePageLineMkgmapCannotProbeIsKnown() {
        XCTAssertTrue(TypSource.codePageTripsMkgmap("[_id]\nCodePage=1252 ;western\n[end]"))
        XCTAssertTrue(TypSource.codePageTripsMkgmap("[_id]\nCodePage=0\n[end]"))
        XCTAssertFalse(TypSource.codePageTripsMkgmap("[_id]\nCodePage=1252\n[end]"))
        XCTAssertFalse(TypSource.codePageTripsMkgmap("; -*- coding: UTF-8 -*-\n[_id]\nCodePage=1252 ;western\n[end]"))
        XCTAssertFalse(TypSource.codePageTripsMkgmap("[_id]\nCodePage = 1252 ;western\n[end]"), "not the probe's line")
        XCTAssertTrue(TypSource.codePageTripsMkgmap("[_id]\nCodePage=01252\n[end]"), "octal to Java")
        XCTAssertTrue(
            TypSource.codePageTripsMkgmap("; -*- mode: typ; coding: utf-8 -*-\n[_id]\nCodePage=1252 ;x\n[end]"),
            "the probe knows only `-*- coding:`"
        )
        XCTAssertEqual(
            TypSource.plainCodePageLine("[_id]\nCodePage=1257 ; Baltic\n[end]"),
            "[_id]\nCodePage=1257\n[end]"
        )
        XCTAssertFalse(TypSource.codePageTripsMkgmap("[_id]\nCodePage=cp1251\n[end]"), "a name Java reads")
        for bad in ["cp65001", "cp+1251", "cp01251"] {
            XCTAssertTrue(TypSource.codePageTripsMkgmap("[_id]\nCodePage=\(bad)\n[end]"), bad)
        }
        XCTAssertTrue(TypSource.codePageTripsMkgmap("; -*- coding: utf-8-unix -*-\n[_id]\n[end]"))
        XCTAssertTrue(TypSource.codePageTripsMkgmap("; -*- coding: -*-\n[_id]\n[end]"), "an empty name")
        XCTAssertFalse(TypSource.codePageTripsMkgmap("; -*- coding: koi8-r -*-\n[_id]\n[end]"))
        XCTAssertTrue(
            TypSource.codePageTripsMkgmap("; -*- coding: utf-8\t-*-\n[_id]\nCodePage=1252 ;x\n[end]"),
            "the probe cuts its charset at a space only"
        )
    }

    /// `CodePage=cp1251` names the page as Java does, and the text is read in it.
    func testACodePageNamedAsJavaNamesItIsRead() {
        var bytes = Array("[_id]\nCodePage=cp1251\n[end]\n[_point]\nType=0x2f\nString=0x00,".utf8)
        bytes += [0xE9]
        bytes += Array("\n[end]\n".utf8)
        let text = TypSource.decoding(bytes).text
        XCTAssertEqual(TypSource.parse(text).section(.point, 0x2f00)?.labels.first?.text, "\u{0439}")
    }

    /// A tab after the coding name is a slip: the text is read by the name before it, and
    /// kmap's copy says UTF-8 plainly.
    func testACodingLineWithATabIsReadByItsName() {
        let bytes = Array("; -*- coding: utf-8\t-*-\n[_point]\nType=0x2f\nString=0x00,\u{0439}\n[end]\n".utf8)
        let decoded = TypSource.decoding(bytes)
        XCTAssertFalse(decoded.byteForByte)
        XCTAssertEqual(TypSource.parse(decoded.text).section(.point, 0x2f00)?.labels.first?.text, "\u{0439}")
        XCTAssertTrue(TypSource.declaringUTF8(decoded.text).hasPrefix(TypSource.codingLine + "\n[_point]"))
    }

    /// mkgmap takes the first coding line: a UTF-8 one under it changes nothing.
    func testTheFirstCodingLineIsTheOneMkgmapTakes() {
        let text = "; -*- coding: cp1251\t-*-\n; -*- coding: utf-8 -*-\n[_id]\n[end]"
        XCTAssertNotEqual(TypSource.declaringUTF8(text), text)
    }

    /// Emacs's forms of a charset name are read as meant: `utf-8;`, `utf-8-unix`, `latin-1`.
    func testEmacsCharsetNamesAreReadAsMeant() {
        for line in ["; -*- coding: utf-8; mode: text -*-", "; -*- coding: utf-8-unix -*-"] {
            let bytes = Array("\(line)\n[_point]\nType=0x2f\nString=0x00,\u{0439}\n[end]\n".utf8)
            let decoded = TypSource.decoding(bytes)
            XCTAssertFalse(decoded.byteForByte, line)
            XCTAssertEqual(TypSource.parse(decoded.text).section(.point, 0x2f00)?.labels.first?.text, "\u{0439}", line)
            XCTAssertTrue(TypSource.codePageTripsMkgmap(decoded.text), line)
        }
        XCTAssertFalse(TypSource.decoding(Array("; -*- coding: latin-1 -*-\n\u{00E9}".utf8)).byteForByte)
        XCTAssertEqual(TypSource.cleanCharset("-*-"), "", "no name at all")
    }

    /// A copy kept byte for byte says no UTF-8: its coding line is put as Java reads it,
    /// or taken out.
    func testACopysCodingLineIsMendedForMkgmap() {
        XCTAssertEqual(
            TypSource.mendedCodingLine("; -*- coding: koi8-r; mode: typ -*-\n[_id]\n[end]"),
            "; -*- coding: koi8-r -*-\n[_id]\n[end]"
        )
        XCTAssertEqual(
            TypSource.mendedCodingLine("; -*- coding: latin-2 -*-\n[_id]\n[end]"),
            "; -*- coding: iso-8859-2 -*-\n[_id]\n[end]",
            "Emacs's name as Java's"
        )
        XCTAssertEqual(
            TypSource.mendedCodingLine("; -*- coding: latin2 -*-\n[_id]\n[end]"),
            "; -*- coding: latin2 -*-\n[_id]\n[end]",
            "a name Java may read stays, as it would in the original"
        )
        XCTAssertEqual(TypSource.mendedCodingLine("; -*- coding: ;; -*-\n[_id]\n[end]"), "[_id]\n[end]", "no name")
        XCTAssertEqual(
            TypSource.mendedCodingLine("; -*- coding: cp1251 -*-\n[_id]\n[end]"),
            "; -*- coding: cp1251 -*-\n[_id]\n[end]"
        )
    }

    /// Java trims only control characters and the space: a no-break space before the name
    /// is in the name.
    func testANoBreakSpaceBeforeTheCodingNameIsInIt() {
        XCTAssertTrue(TypSource.codePageTripsMkgmap("; -*- coding:\u{00A0}utf-8 -*-\n[_id]\n[end]"))
    }

    /// A legal name Java may read passes, as it would in the original; names known not to
    /// be Java's trip; a name is trimmed at both ends, as Java trims it.
    func testCharsetNamesTripOnlyWhereJavaIsKnownToRefuseThem() {
        func trips(_ name: String) -> Bool {
            TypSource.codePageTripsMkgmap("; -*- coding: \(name) -*-\n[_id]\n[end]")
        }
        for good in ["koi8", "latin2", "windows-874", "gbk", "iso-8859-5"] { XCTAssertFalse(trips(good), good) }
        for bad in ["iso-8859-14", "latin-2", "utf-8-unix", "cp65001"] { XCTAssertTrue(trips(bad), bad) }
        XCTAssertFalse(TypSource.codePageTripsMkgmap("; -*- coding: koi8-r\t\n[_id]\n[end]"), "trimmed at the end")
    }

    /// A name no Java reads even cleaned, over bytes that are UTF-8, is read as UTF-8; a
    /// name kmap can mend keeps its own charset, as short text in it may read as UTF-8.
    func testOnlyAnUnmendableNameOverUTF8IsReadAsUTF8() {
        func decoded(_ name: String, _ label: [UInt8]) -> (String?, Bool) {
            let bytes =
                Array("; -*- coding: \(name) -*-\n[_point]\nType=0x2f\nString=0x00,".utf8) + label
                + Array("\n[end]\n".utf8)
            let read = TypSource.decoding(bytes)
            return (TypSource.parse(read.text).section(.point, 0x2f00)?.labels.first?.text, read.byteForByte)
        }
        XCTAssertEqual(decoded("iso-8859-14", Array("\u{0141}\u{0105}ka".utf8)).0, "\u{0141}\u{0105}ka")
        XCTAssertTrue(decoded("latin-2", [0xC3, 0xA1]).1, "Latin-2 bytes, kept as they are")
        XCTAssertEqual(TypSource.cleanCharset("iso8859_16"), "iso-8859-16")
        XCTAssertEqual(TypSource.cleanCharset("latin-0"), "iso-8859-15")
        XCTAssertFalse(TypSource.codePageTripsMkgmap("; -*- coding: latin-9 -*-\n[_id]\n[end]"), "Java reads it")
    }

    /// The coding line in line 2 is read however long line 1 is.
    func testACodingLineAfterALongFirstLineIsRead() {
        let first = "; " + String(repeating: "x", count: 600) + "\n"
        let bytes =
            Array((first + "; -*- coding: cp1251 -*-\n[_point]\nType=0x2f\nString=0x00,").utf8) + [0xE9]
            + Array("\n[end]\n".utf8)
        XCTAssertEqual(
            TypSource.parse(TypSource.decoding(bytes).text).section(.point, 0x2f00)?.labels.first?.text,
            "\u{0439}"
        )
    }
}
