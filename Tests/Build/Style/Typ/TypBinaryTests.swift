import XCTest
@testable import kmap

/// Reading a compiled TYP.
///
/// The layout follows the mkgmap writer and carries its self-check: every element must
/// end exactly where the next one in its index begins.
final class TypBinaryTests: XCTestCase {

    /// Compiled TYPs on this machine and what reading them must produce. They cannot
    /// be committed, so the paths and expectations live outside the repository; see
    /// `LocalTestMaps`. Where the file is absent the tests skip.
    private func compiledTyps() throws -> [LocalTestMaps.Typ] {
        let listed = (LocalTestMaps.load()?.typ ?? []).filter {
            FileTools.exists(URL(fileURLWithPath: $0.path))
        }
        try XCTSkipUnless(!listed.isEmpty, "no compiled TYP listed for this machine")
        return listed
    }

    // MARK: Refusing what is not a TYP

    func testAFileWithoutTheSignatureIsRefused() {
        var bytes = [UInt8](repeating: 0, count: 0x80)
        bytes[0] = 0x5B
        XCTAssertThrowsError(try TypBinary.decode(bytes)) { error in
            XCTAssertEqual(error as? TypBinary.ReadError, .notATyp)
        }
    }

    func testAFileTooShortToHoldAHeaderIsRefused() {
        XCTAssertThrowsError(try TypBinary.decode([UInt8](repeating: 0, count: 8)))
    }

    // MARK: Type codes

    /// The mkgmap compiler splits a written type on magnitude: above 0xff it is a type and
    /// subtype pair, so an extended type keeps its trailing zeros.
    func testHowATypeAndSubtypeCombineIntoTheWrittenCode() {
        func code(_ kind: MapElementKind, _ type: Int, _ subtype: Int) -> Int {
            TypBinary.Element(kind: kind, type: type, subtype: subtype, colours: [],
                              bitmap: nil, bitmapHeight: 0, dayImage: nil, nightImage: nil,
                              labels: [], fontStyle: nil, dayLabelColour: nil,
                              nightLabelColour: nil, lineWidth: nil, borderWidth: nil,
                              usesOrientation: false, exact: true).code
        }
        XCTAssertEqual(code(.polygon, 0x16, 0), 0x16, "a plain type stays as it is")
        XCTAssertEqual(code(.point, 0x2a, 0), 0x2a00, "a point always folds its subtype in")
        XCTAssertEqual(code(.line, 0x108, 1), 0x10801, "an extended type folds its subtype in")
        XCTAssertEqual(code(.polygon, 0x101, 0), 0x10100,
                       "an extended type with no subtype keeps its trailing zeros")
    }

    // MARK: Palette depth

    func testTheBitsPerPixelLadder() {
        XCTAssertEqual(TypBinary.bitsPerPixel(forColours: 1), 1)
        XCTAssertEqual(TypBinary.bitsPerPixel(forColours: 2), 2)
        XCTAssertEqual(TypBinary.bitsPerPixel(forColours: 3), 2)
        XCTAssertEqual(TypBinary.bitsPerPixel(forColours: 4), 4)
        XCTAssertEqual(TypBinary.bitsPerPixel(forColours: 15), 4)
        XCTAssertEqual(TypBinary.bitsPerPixel(forColours: 16), 8)
        XCTAssertEqual(TypBinary.bitsPerPixel(forColours: 256), 8)
    }

    /// The code page decides which alphabet the labels decode to; a wrong page does not
    /// fail but yields plausible rubbish. Checked on the decoded letters rather than on
    /// which encoding object is chosen.
    func testTheCodePageDecidesTheAlphabet() {
        let moscow: [UInt8] = [0xCC, 0xEE, 0xF1, 0xEA, 0xE2, 0xE0]
        XCTAssertEqual(CodePage.decodeLenient(moscow, codePage: 1251), "Москва")
        XCTAssertEqual(CodePage.decodeLenient(moscow, codePage: 1252), "Ìîñêâà",
                       "the symptom a wrong page produces, and the reason it has to be right")
        XCTAssertEqual(CodePage.decodeLenient(Array("Москва".utf8), codePage: 65001), "Москва")
        // A page with no table reads as Latin-1 rather than as nothing.
        XCTAssertEqual(CodePage.decodeLenient(moscow, codePage: 0), "Ìîñêâà")
    }

    // MARK: Against compiled files

    func testACompiledFileReadsBackWithItsCountsAndLabels() throws {
        for expected in try compiledTyps() {
            let url = URL(fileURLWithPath: expected.path)
            let typ = try TypBinary.read(url)
            let name = url.lastPathComponent

            XCTAssertEqual(typ.familyID, expected.familyID, name)
            XCTAssertEqual(typ.codePage, expected.codePage, name)
            XCTAssertEqual(typ.polygons.count, expected.polygons, name)
            XCTAssertEqual(typ.lines.count, expected.lines, name)
            XCTAssertEqual(typ.points.count, expected.points, name)
            XCTAssertEqual(typ.exactCount, expected.exact, name)
            XCTAssertEqual(typ.all.count, expected.all, name)
            XCTAssertEqual(typ.all.filter { !$0.exact }.map(\.code).sorted(),
                           expected.inexactCodes, name)

            // A file in a single-byte code page read as anything else comes back as
            // accented Latin.
            for label in expected.labels {
                let element = try XCTUnwrap(typ.all.first { $0.code == label.code }, name)
                XCTAssertEqual(element.labels.first { $0.language == label.language }?.text,
                               label.text, name)
            }

            // A cased line: fill and casing, day and night.
            if let line = expected.line {
                let element = try XCTUnwrap(typ.lines.first { $0.code == line.code }, name)
                XCTAssertEqual(element.colours.compactMap { $0 }, line.colours, name)
                XCTAssertEqual(element.lineWidth, line.lineWidth, name)
                XCTAssertEqual(element.borderWidth, line.borderWidth, name)
            }
        }
    }

    /// A pattern read straight through comes out inverted: for the one-bit palettes of
    /// lines and polygons the stored bit is the complement of the palette index.
    func testAPatternIsNotInverted() throws {
        for expected in try compiledTyps() {
            let typ = try TypBinary.read(URL(fileURLWithPath: expected.path))
            for element in typ.polygons where element.bitmap != nil {
                let bitmap = try XCTUnwrap(element.bitmap)
                XCTAssertEqual(bitmap.count, 32)
                XCTAssertTrue(bitmap.allSatisfy { $0.count == 32 })
                // Every index must address a colour the element actually has.
                let highest = bitmap.flatMap { $0 }.max() ?? 0
                XCTAssertLessThan(highest, max(2, element.colours.count),
                                  "\(TypeMeaning.hex(element.code)) indexes past its palette")
            }
        }
    }

    /// An element that cannot be read is kept and flagged rather than dropped, so the file
    /// does not look smaller, nor the decode more complete, than it is.
    func testAnElementThatCannotBeReadIsKeptAndFlagged() throws {
        for expected in try compiledTyps() where expected.all > expected.exact {
            let typ = try TypBinary.read(URL(fileURLWithPath: expected.path))
            let refused = typ.all.filter { !$0.exact }
            XCTAssertEqual(refused.count, expected.all - expected.exact)
            XCTAssertEqual(typ.lines.count, expected.lines, "the refused are still listed")
        }
    }

    // MARK: Decompiling a compiled file

    /// Everything a compiled file carries has to survive being written out and read back.
    func testACompiledFileSurvivesDecompilingAndBeingReadBack() throws {
        for expected in try compiledTyps() {
            let url = URL(fileURLWithPath: expected.path)
            let name = url.lastPathComponent
            let typ = try TypBinary.read(url)
            let source = TypSource.parse(TypDecompiler.source(typ, origin: name))

            XCTAssertEqual(source.familyID, typ.familyID, name)
            XCTAssertEqual(source.codePage, typ.codePage, name)

            // Everything readable, and only that: an element with nothing to draw with is
            // left out, and a section with no Xpm is refused by the compiler.
            for kind in MapElementKind.allCases {
                let usable = Set(typ.elements(kind).filter(TypDecompiler.isUsable).map(\.code))
                XCTAssertEqual(source.codes(kind), usable, "\(name): \(kind.rawValue) codes")
            }
            for element in typ.all where !TypDecompiler.isUsable(element) {
                XCTAssertFalse(element.exact,
                               "\(name): \(TypeMeaning.hex(element.code)) decoded cleanly and "
                               + "was still left out")
            }

            // A styled polygon absent from the draw order is never drawn. Some files
            // arrive that way; what must not happen is the decompiler losing an entry
            // the file did have.
            let ordered = Set(typ.drawOrder.map(\.code))
            for code in source.polygonsMissingFromDrawOrder {
                XCTAssertFalse(ordered.contains(code),
                               "\(name): \(TypeMeaning.hex(code)) lost its draw order")
            }

            // Every picture must agree with its own header, or its pixels resolve against
            // colours that are not there.
            for section in source.sections {
                guard let picture = section.picture else { continue }
                XCTAssertEqual(picture.palette.count, picture.declaredColours,
                               "\(name) \(section.hex)")
                XCTAssertEqual(picture.rows.count, picture.height, "\(name) \(section.hex)")
            }
        }
    }
}
