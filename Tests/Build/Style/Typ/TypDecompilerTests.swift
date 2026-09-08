import XCTest
@testable import kmap

/// Writing a decoded TYP back out as source.
///
/// What the decompiler writes, the source parser must read back as the same thing. The two
/// follow different specifications: the mkgmap binary writer and its text compiler.
final class TypDecompilerTests: XCTestCase {

    private func element(_ kind: MapElementKind, type: Int, subtype: Int = 0,
                         colours: [String?] = ["#A0D070"],
                         bitmap: [[Int]]? = nil, bitmapHeight: Int = 0,
                         dayImage: TypBinary.PointImage? = nil,
                         nightImage: TypBinary.PointImage? = nil,
                         labels: [(language: Int, text: String)] = [],
                         fontStyle: String? = nil,
                         dayLabelColour: String? = nil,
                         lineWidth: Int? = nil, borderWidth: Int? = nil,
                         usesOrientation: Bool = false,
                         exact: Bool = true) -> TypBinary.Element {
        TypBinary.Element(kind: kind, type: type, subtype: subtype, colours: colours,
                          bitmap: bitmap, bitmapHeight: bitmapHeight,
                          dayImage: dayImage, nightImage: nightImage, labels: labels,
                          fontStyle: fontStyle, dayLabelColour: dayLabelColour,
                          nightLabelColour: nil, lineWidth: lineWidth,
                          borderWidth: borderWidth, usesOrientation: usesOrientation,
                          exact: exact)
    }

    private func binary(_ elements: [TypBinary.Element],
                        drawOrder: [(code: Int, level: Int)] = [],
                        codePage: Int = 1252) -> TypBinary {
        TypBinary(codePage: codePage, familyID: 6324, productID: 1,
                  polygons: elements.filter { $0.kind == .polygon },
                  lines: elements.filter { $0.kind == .line },
                  points: elements.filter { $0.kind == .point },
                  drawOrder: drawOrder)
    }

    /// Decompile, then read the result back with the source parser.
    private func roundTrip(_ typ: TypBinary) -> TypSource {
        TypSource.parse(TypDecompiler.source(typ))
    }

    // MARK: Identity

    func testTheIdentityBlockSurvives() {
        let source = roundTrip(binary([element(.polygon, type: 0x16)], codePage: 1251))
        XCTAssertEqual(source.familyID, 6324)
        XCTAssertEqual(source.productID, 1)
        XCTAssertEqual(source.codePage, 1251)
    }

    // MARK: Type codes

    func testAPlainTypeIsWrittenAsTwoDigits() {
        let source = roundTrip(binary([element(.polygon, type: 0x16)]))
        XCTAssertNotNil(source.section(.polygon, 0x16))
    }

    /// A point folds its subtype in even when the subtype is zero: `Type=0x2a00`.
    func testAPointFoldsItsSubtypeIn() {
        let image = TypBinary.PointImage(width: 1, height: 1, palette: ["#FF0000"],
                                         pixels: [[0]])
        let source = roundTrip(binary([element(.point, type: 0x2a, dayImage: image)]))
        XCTAssertNotNil(source.section(.point, 0x2a00))
    }

    /// The compiler splits on magnitude: above 0xff a written type is a type and subtype
    /// pair, so an extended type with no subtype keeps its trailing zeros.
    func testAnExtendedTypeWithNoSubtypeKeepsItsTrailingZeros() {
        let source = roundTrip(binary([element(.polygon, type: 0x101, subtype: 0)]))
        XCTAssertNotNil(source.section(.polygon, 0x10100))
        XCTAssertNil(source.section(.polygon, 0x101))
    }

    func testAnExtendedTypeCarriesItsSubtype() {
        let source = roundTrip(binary([element(.line, type: 0x108, subtype: 1,
                                               lineWidth: 1)]))
        XCTAssertNotNil(source.section(.line, 0x10801))
    }

    // MARK: Colours

    func testSolidDayAndNightColoursComeBackInOrder() throws {
        let source = roundTrip(binary([element(.polygon, type: 0x16,
                                               colours: ["#A0D070", "#204020"])]))
        XCTAssertEqual(try XCTUnwrap(source.section(.polygon, 0x16)).colours,
                       ["#A0D070", "#204020"])
    }

    /// `none` belongs to a pattern, where it lets the ground show through. In a solid Xpm
    /// the compiler counts it as a colour and every tag after it reads one slot out of step.
    func testATransparentSlotIsDroppedFromASolidElementRatherThanWrittenAsNone() throws {
        let source = roundTrip(binary([element(.line, type: 0x15,
                                               colours: ["#1864D0", nil],
                                               lineWidth: 1, borderWidth: 0)]))
        let section = try XCTUnwrap(source.section(.line, 0x15))
        XCTAssertEqual(section.colours, ["#1864D0"], "one colour, not a colour and a none")
        XCTAssertEqual(section.lineWidth, 1)
    }

    /// A zero border must not be written. The tag is what tells the compiler that two
    /// colours mean fill and casing rather than day and night.
    func testAZeroBorderIsNotWritten() throws {
        let source = roundTrip(binary([element(.line, type: 0x15,
                                               colours: ["#1864D0", "#000000"],
                                               lineWidth: 2, borderWidth: 0)]))
        XCTAssertNil(try XCTUnwrap(source.section(.line, 0x15)).borderWidth)
    }

    func testARealBorderIsWritten() throws {
        let source = roundTrip(binary([element(.line, type: 0x07,
                                               colours: ["#D0D4D0", "#404040"],
                                               lineWidth: 1, borderWidth: 1)]))
        let section = try XCTUnwrap(source.section(.line, 0x07))
        XCTAssertEqual(section.lineWidth, 1)
        XCTAssertEqual(section.borderWidth, 1)
    }

    // MARK: Patterns and icons

    func testAPolygonPatternComesBackAsThirtyTwoRows() throws {
        let rows = (0..<32).map { y in (0..<32).map { x in (x + y) % 2 } }
        let source = roundTrip(binary([element(.polygon, type: 0x51,
                                               colours: ["#789400", nil],
                                               bitmap: rows, bitmapHeight: 32)]))
        let picture = try XCTUnwrap(source.section(.polygon, 0x51)?.picture)
        XCTAssertEqual(picture.width, 32)
        XCTAssertEqual(picture.height, 32)
        XCTAssertEqual(picture.pixels()?.first ?? [], (0..<32).map { $0 % 2 == 0 ? "#789400" : nil })
    }

    /// A line's pattern is 32 long and as many rows deep as the line is thick.
    func testALinePatternKeepsItsThickness() throws {
        let rows = [Array(repeating: 0, count: 32), Array(repeating: 1, count: 32)]
        let source = roundTrip(binary([element(.line, type: 0x23,
                                               colours: ["#789400", nil],
                                               bitmap: rows, bitmapHeight: 2,
                                               usesOrientation: true)]))
        let section = try XCTUnwrap(source.section(.line, 0x23))
        XCTAssertTrue(section.usesOrientation)
        XCTAssertEqual(section.picture?.height, 2)
        XCTAssertEqual(section.picture?.pixels()?[1].first ?? "x", String?.none)
    }

    func testAPointIconKeepsItsSizeAndPalette() throws {
        let image = TypBinary.PointImage(
            width: 3, height: 2,
            palette: ["#F80000", nil, "#FFFFFF"],
            pixels: [[0, 1, 2], [2, 1, 0]])
        let source = roundTrip(binary([element(.point, type: 0x2a, subtype: 0,
                                               colours: [], dayImage: image)]))
        let picture = try XCTUnwrap(source.section(.point, 0x2a00)?.picture)
        XCTAssertEqual(picture.width, 3)
        XCTAssertEqual(picture.height, 2)
        XCTAssertEqual(picture.pixels() ?? [],
                       [["#F80000", nil, "#FFFFFF"], ["#FFFFFF", nil, "#F80000"]])
    }

    func testANightIconIsWrittenSeparately() throws {
        let day = TypBinary.PointImage(width: 1, height: 1, palette: ["#FFFFFF"], pixels: [[0]])
        let night = TypBinary.PointImage(width: 1, height: 1, palette: ["#000000"], pixels: [[0]])
        let source = roundTrip(binary([element(.point, type: 0x2a, colours: [],
                                               dayImage: day, nightImage: night)]))
        let section = try XCTUnwrap(source.section(.point, 0x2a00))
        XCTAssertEqual(section.dayXpm?.colours, ["#FFFFFF"])
        XCTAssertEqual(section.nightXpm?.colours, ["#000000"])
    }

    /// Past the length of the one-character alphabet the palette keys widen, and the pixel
    /// rows widen with them or every row resolves against the wrong entries.
    func testAPaletteDeeperThanTheAlphabetWidensItsKeys() throws {
        let palette: [String?] = (0..<200).map { String(format: "#%02X0000", $0) }
        let image = TypBinary.PointImage(width: 4, height: 1, palette: palette,
                                         pixels: [[0, 91, 92, 199]])
        let source = roundTrip(binary([element(.point, type: 0x2a, colours: [],
                                               dayImage: image)]))
        let picture = try XCTUnwrap(source.section(.point, 0x2a00)?.picture)
        XCTAssertEqual(picture.charsPerPixel, 2)
        XCTAssertEqual(picture.declaredColours, 200)
        XCTAssertEqual(picture.pixels()?.first ?? [],
                       ["#000000", "#5B0000", "#5C0000", "#C70000"])
    }

    // MARK: Labels and styling

    func testEveryLabelLanguageSurvives() throws {
        let source = roundTrip(binary([element(.polygon, type: 0x16,
                                               labels: [(0x00, "Nature reserve"),
                                                        (0x19, "Заповедник")])]))
        let section = try XCTUnwrap(source.section(.polygon, 0x16))
        XCTAssertEqual(section.englishLabel, "Nature reserve")
        XCTAssertEqual(section.russianLabel, "Заповедник")
    }

    /// A label with no text is reconstructed as it stands rather than tidied away.
    func testALabelWithNoTextIsStillWritten() throws {
        let source = roundTrip(binary([element(.line, type: 0x18,
                                               labels: [(0x01, ""), (0x04, "Stream")],
                                               lineWidth: 1)]))
        let section = try XCTUnwrap(source.section(.line, 0x18))
        XCTAssertEqual(section.labels.count, 2)
        XCTAssertEqual(section.label(language: 0x01), "")
    }

    /// Omitting FontStyle leaves the size to the receiver, which is a different instruction
    /// from naming the default.
    func testTheDefaultFontStyleIsOmittedRatherThanNamed() throws {
        let plain = roundTrip(binary([element(.polygon, type: 0x16, fontStyle: "Default")]))
        XCTAssertNil(try XCTUnwrap(plain.section(.polygon, 0x16)).fontStyle)

        let named = roundTrip(binary([element(.polygon, type: 0x16, fontStyle: "NoLabel")]))
        XCTAssertEqual(try XCTUnwrap(named.section(.polygon, 0x16)).fontStyle, "NoLabel")
    }

    func testALabelColourSurvives() throws {
        let source = roundTrip(binary([element(.line, type: 0x20,
                                               dayLabelColour: "#685820",
                                               lineWidth: 1)]))
        XCTAssertEqual(try XCTUnwrap(source.section(.line, 0x20)).dayLabelColour, "#685820")
    }

    // MARK: Draw order

    /// A polygon absent from the draw order is not drawn, so every entry has to arrive.
    /// Levels are renumbered from one: the table encodes stacking order, not the originals.
    func testTheDrawOrderArrivesWholeWithItsLevelsInOrder() {
        let source = roundTrip(binary(
            [element(.polygon, type: 0x16), element(.polygon, type: 0x51)],
            drawOrder: [(0x51, 4), (0x16, 9)]))
        XCTAssertEqual(source.drawOrder.map(\.code), [0x51, 0x16])
        XCTAssertEqual(source.drawOrder.map(\.level), [1, 2], "renumbered, order kept")
        XCTAssertEqual(source.polygonsMissingFromDrawOrder, [])
    }

    func testAnExtendedTypeInTheDrawOrderKeepsItsSubtype() {
        let source = roundTrip(binary([], drawOrder: [(0x10409, 2), (0x10405, 2)]))
        XCTAssertEqual(Set(source.drawOrder.map(\.code)), [0x10409, 0x10405])
    }

    // MARK: Saying what was not understood

    /// An element with nothing readable to draw with is left out rather than given an
    /// invented colour; a section with no Xpm is refused by the compiler.
    func testAnElementWithNothingToDrawWithIsLeftOutEntirely() {
        let text = TypDecompiler.source(binary([
            element(.polygon, type: 0x16, colours: ["#A0D070"]),
            element(.line, type: 0x104, subtype: 5, colours: [], exact: false)]))

        let source = TypSource.parse(text)
        XCTAssertNotNil(source.section(.polygon, 0x16), "the readable one stays")
        XCTAssertNil(source.section(.line, 0x10405), "the unreadable one goes")
        XCTAssertFalse(text.contains("#FF00FF"), "nothing is invented for it")
    }

    /// A type missing from the file is drawn the receiver's own way, so it is named in the
    /// header rather than only counted.
    func testTheHeaderNamesWhatWasLeftOut() {
        let text = TypDecompiler.source(binary([
            element(.polygon, type: 0x16, colours: ["#A0D070"]),
            element(.line, type: 0x104, subtype: 5, colours: [], exact: false)]))
        XCTAssertTrue(text.contains("1 element(s) had nothing readable"), text)
        XCTAssertTrue(text.contains("line 0x10405"), text)
    }

    /// An element that did not end where the next began, but whose colours and width read,
    /// is kept and marked rather than dropped.
    func testAnElementThatIsInexactButReadableIsKeptAndMarked() throws {
        let text = TypDecompiler.source(binary([
            element(.line, type: 0x104, subtype: 6, colours: ["#333333", nil],
                    lineWidth: 15, exact: false)]))
        XCTAssertTrue(text.contains("NOT FULLY DECODED"), text)

        let section = try XCTUnwrap(TypSource.parse(text).section(.line, 0x10406))
        XCTAssertEqual(section.colours, ["#333333"])
        XCTAssertEqual(section.lineWidth, 15)
    }

    func testTheHeaderSaysHowMuchOfTheFileWasUnderstood() {
        let clean = TypDecompiler.source(binary([element(.polygon, type: 0x16)]))
        XCTAssertTrue(clean.contains("Every one of the 1 elements"), clean)

        let partial = TypDecompiler.source(binary([
            element(.polygon, type: 0x16),
            element(.line, type: 0x104, subtype: 6, colours: ["#333333"], exact: false)]))
        XCTAssertTrue(partial.contains("1 of 2 elements"), partial)
        XCTAssertTrue(partial.contains("NOT FULLY DECODED"))
    }

    // MARK: Reproducibility

    /// The same TYP decompiles to the same text, so a file can be diffed against an
    /// earlier copy of itself.
    func testDecompilingTwiceGivesTheSameText() {
        let typ = binary([element(.polygon, type: 0x16, colours: ["#A0D070", "#204020"]),
                          element(.line, type: 0x23, lineWidth: 2)],
                         drawOrder: [(0x16, 1)])
        XCTAssertEqual(TypDecompiler.source(typ), TypDecompiler.source(typ))
    }

    func testTheOriginIsNamedInTheHeaderSoAnOldCopyStillSaysWhereItCameFrom() {
        let text = TypDecompiler.source(binary([element(.polygon, type: 0x16)]),
                                        origin: "STYLE.TYP")
        XCTAssertTrue(text.contains("STYLE.TYP"), text)
    }
}
