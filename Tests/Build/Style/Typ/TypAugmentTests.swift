import XCTest
@testable import kmap

/// Covers appending the repair sections to whatever TYP a build uses: the repair pass emits
/// two types no other style draws, and the sections travel with the build, are added only
/// where they are missing, and are never written into the imported file.
final class TypAugmentTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("augment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: self.folder) }
    }

    private func write(_ text: String, as name: String = "style.txt") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: The file the user owns

    /// The copy is named after the original, so a destination folder holding the original
    /// would be written over; the build goes on with the original instead, and says so.
    func testACopyIsNeverWrittenOverTheOriginal() throws {
        let url = try write(TypFixture.source)
        let before = try String(contentsOf: url, encoding: .utf8)

        let result = try XCTUnwrap(TypAugment.prepare(url, theme: .day, into: folder))

        XCTAssertEqual(result.url, url, "the build uses the original as it is")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), before,
                       "and the original is byte for byte what it was")
        XCTAssertNotNil(result.refusal, "silently building something else would be worse")
        XCTAssertEqual(result.added, [])
    }

    /// A copy belongs to the build that asked for it and carries that build's theme, so a
    /// build asking for another theme is not handed it.
    func testTheCopyGoesWhereTheBuildAsksForIt() throws {
        let url = try write(TypFixture.source)
        let scratch = folder.appendingPathComponent("build", isDirectory: true)

        let result = try XCTUnwrap(TypAugment.prepare(url, theme: .day, into: scratch))

        XCTAssertEqual(result.url.deletingLastPathComponent().standardizedFileURL,
                       scratch.standardizedFileURL)
        XCTAssertNotEqual(result.url, url)
        XCTAssertNotNil(result.theme)
    }

    // MARK: What gets added

    func testAStyleThatDrawsNeitherGetsBoth() throws {
        let url = try write(TypFixture.source)
        let result = try XCTUnwrap(TypAugment.prepare(url))

        XCTAssertEqual(result.added.count, 2)
        XCTAssertNil(result.refusal)

        let after = TypSource.parse(try String(contentsOf: result.url, encoding: .utf8))
        XCTAssertNotNil(after.section(.line, 0x0d))
        XCTAssertNotNil(after.section(.point, 0x660b))
    }

    /// Appending must not disturb the file, only lengthen it.
    func testEveryOriginalSectionSurvives() throws {
        let url = try write(TypFixture.source)
        let before = TypSource.parse(TypFixture.source)
        let result = try XCTUnwrap(TypAugment.prepare(url))
        let after = TypSource.parse(try String(contentsOf: result.url, encoding: .utf8))

        for kind in MapElementKind.allCases {
            XCTAssertTrue(before.codes(kind).isSubset(of: after.codes(kind)),
                          "\(kind.rawValue) sections went missing")
        }
        XCTAssertEqual(after.familyID, before.familyID)
        XCTAssertEqual(after.codePage, before.codePage)
        XCTAssertEqual(after.drawOrder.count, before.drawOrder.count)
        XCTAssertTrue(try String(contentsOf: result.url, encoding: .utf8)
            .hasPrefix(TypFixture.source.trimmingCharacters(in: .newlines)),
                      "the original text must come first and unchanged")
    }

    // MARK: What does not get added

    /// A style that already draws both keeps its own sections; nothing is appended.
    func testAStyleThatAlreadyDrawsThemIsLeftCompletelyAlone() throws {
        let mine = TypFixture.source + """

            [_line]
            Type=0x0d
            ; my own repair link, and it must survive
            Xpm="0 0 1 0"
            "a c #D40000"
            String=0x00,Repaired link
            [end]

            [_point]
            Type=0x660b
            DayXpm="2 2 1 1"
            "a c #D40000"
            "aa"
            "aa"
            String=0x00,Repaired link
            [end]

            """
        let url = try write(mine)
        let result = try XCTUnwrap(TypAugment.prepare(url))

        XCTAssertEqual(result.added, [])
        XCTAssertEqual(result.url, url, "the build must compile the file as it stands")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), mine)
    }

    /// A style using kmap's numbers for its own vocabulary — a pedestrian street on
    /// 0x0d — keeps its drawing, and the mark moves to a number left free.
    func testAMarkMovesOffANumberTheStyleMeansSomethingElseBy() throws {
        let theirs = TypFixture.source + """

            [_line]
            Type=0x0d
            Xpm="0 0 1 0"
            "a c #FEFEFE"
            String=0x00,Pedestrian street
            [end]

            """
        let result = try XCTUnwrap(TypAugment.prepare(try write(theirs)))
        let moved = try XCTUnwrap(result.moved[.line]?[0x0d])
        XCTAssertNotEqual(moved, 0x0d)
        XCTAssertTrue(TypAugment.routableLines.contains(moved),
                      "a link the receiver will not route on is not a repair link")

        let after = TypSource.parse(try String(contentsOf: result.url, encoding: .utf8))
        XCTAssertEqual(after.section(.line, 0x0d)?.englishLabel, "Pedestrian street",
                       "their own drawing is untouched")
        XCTAssertEqual(after.section(.line, moved)?.englishLabel,
                       TypAugment.repairLabel, "the mark is drawn where it moved")
    }

    /// The number the link moves to has to be free twice over: the borrowed style must not
    /// draw it, and kmap's own rules must not emit it, or every footway sharing it would
    /// be drawn as a repair link.
    func testTheLinkMovesPastTheNumbersOurOwnRulesEmit() throws {
        let theirs = TypFixture.source + """

            [_line]
            Type=0x0d
            Xpm="0 0 1 0"
            "a c #FEFEFE"
            String=0x00,Pedestrian street
            [end]

            """
        // Every routing number but 0x13 spoken for, the way kmap's rule set has it.
        let rules = folder.appendingPathComponent("rules", isDirectory: true)
        try FileManager.default.createDirectory(at: rules, withIntermediateDirectories: true)
        let used = (0x01...0x16).filter { $0 != 0x13 }
            .map { String(format: "highway=x [0x%02x resolution 23]", $0) }
        try used.joined(separator: "\n").write(to: rules.appendingPathComponent("lines"),
                                               atomically: true, encoding: .utf8)

        let result = try XCTUnwrap(TypAugment.prepare(try write(theirs), rules: rules))
        XCTAssertEqual(result.moved[.line]?[0x0d], 0x13,
                       "the one routing number nothing else means")
    }

    /// A style that draws the link but not the mark keeps its own link.
    func testOnlyWhatIsMissingIsAdded() throws {
        // Labelled as kmap labels its own: this is the repair link, drawn the style's
        // own way, and it is left alone.
        let half = TypFixture.source + """

            [_line]
            Type=0x0d
            ; my own repair link
            Xpm="0 0 1 0"
            "a c #D40000"
            String=0x00,Repaired link
            [end]

            """
        let result = try XCTUnwrap(TypAugment.prepare(try write(half)))

        XCTAssertEqual(result.added.count, 1)
        XCTAssertTrue(result.added[0].contains("0x660b"), result.added[0])

        let after = TypSource.parse(try String(contentsOf: result.url, encoding: .utf8))
        XCTAssertEqual(after.section(.line, 0x0d)?.englishLabel, "Repaired link",
                       "the style's own link must survive")
        XCTAssertNotNil(after.section(.point, 0x660b))
    }

    // MARK: The file the user owns

    func testTheOriginalIsNeverWrittenTo() throws {
        let url = try write(TypFixture.source)
        let before = try Data(contentsOf: url)
        let result = try XCTUnwrap(TypAugment.prepare(url))

        XCTAssertNotEqual(result.url, url)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertFalse(TypLibrary.mayWrite(to: result.url),
                       "the augmented copy is a build artefact, not a library entry")
    }

    // MARK: What cannot be done

    /// A compiled TYP has no text to append to; the build uses it and reports the reason.
    func testACompiledTypIsBuiltWithAnywayAndTheReasonIsGiven() throws {
        var bytes = [UInt8](repeating: 0, count: 0x60)
        bytes[0] = 0x5B
        for (i, b) in Array("GARMIN TYP".utf8).enumerated() { bytes[2 + i] = b }
        bytes[0x2F] = 1
        let url = folder.appendingPathComponent("compiled.typ")
        try Data(bytes).write(to: url)

        let result = try XCTUnwrap(TypAugment.prepare(url))
        XCTAssertEqual(result.url, url, "it must still be built with")
        XCTAssertEqual(result.added, [])
        let refusal = try XCTUnwrap(result.refusal)
        XCTAssertTrue(refusal.contains("import"), refusal)
    }

    func testAStyleWithNoTypAtAllIsNotAProblem() {
        XCTAssertNil(TypAugment.prepare(nil))
        XCTAssertNil(TypAugment.prepare(folder.appendingPathComponent("nothing.txt")))
    }

    // MARK: The shipped sections themselves

    /// They have to parse, or a build would compile a TYP with rubbish appended to it.
    func testTheShippedRepairSectionsAreWellFormed() throws {
        let sections = TypAugment.sections(of: StyleAssets.repairMarks)
        XCTAssertEqual(sections.map(\.code).sorted(), [0x0d, 0x660b])

        let source = TypSource.parse(StyleAssets.repairMarks)
        let link = try XCTUnwrap(source.section(.line, 0x0d))
        let mark = try XCTUnwrap(source.section(.point, 0x660b))

        // The link is a dashed band; the mark is a full-size badge.
        XCTAssertEqual(link.picture?.width, 32)
        XCTAssertEqual(mark.picture?.width, 20)
        XCTAssertEqual(mark.picture?.height, 20)

        // Both name themselves in English and Russian; English is the fallback used when
        // the receiver's own language has no entry.
        for section in [link, mark] {
            XCTAssertNotNil(section.englishLabel, section.hex)
            XCTAssertNotNil(section.russianLabel, section.hex)
        }

        // Every picture must agree with its own header, or pixels resolve against colours
        // that are not there.
        for section in [link, mark] {
            guard let picture = section.picture else { continue }
            XCTAssertEqual(picture.palette.count, picture.declaredColours, section.hex)
            XCTAssertEqual(picture.rows.count, picture.height, section.hex)
        }
    }

    func testTheSectionsDrawTheCodesTheRepairPassEmits() {
        XCTAssertEqual(TypAugment.repairTypes.map(\.code).sorted(), [0x0d, 0x660b])
        for entry in TypAugment.repairTypes {
            XCTAssertNotNil(TypSource.parse(StyleAssets.repairMarks)
                .section(entry.kind, entry.code), TypeMeaning.hex(entry.code))
        }
    }

    /// The compiler reads a draw-order entry to the end of its line, so a note behind
    /// the level compiles to nothing. Files kmap damaged that way are mended.
    func testANoteBehindADrawOrderLevelIsMendedForTheBuild() {
        let damaged = """
            [_drawOrder]
            Type=0x16,1
            Type=0x30,9  ; added by kmap
            [end]

            [_polygon]
            Type=0x30
            Xpm="0 0 1 0"
            "1 c #FF00FF"  ; a comment here is fine
            [end]
            """
        let mended = TypAugment.repairedDrawOrder(damaged)
        XCTAssertTrue(mended.contains("Type=0x30,9\n"), "the entry keeps its level")
        XCTAssertFalse(mended.contains("added by kmap"))
        XCTAssertTrue(mended.contains("\"1 c #FF00FF\"  ; a comment here is fine"),
                      "only the draw-order table is touched")
    }

    /// A file with nothing to mend comes back as it was, byte for byte.
    func testAnUndamagedTypIsNotRewritten() {
        let clean = "[_drawOrder]\nType=0x16,1\n[end]\n"
        XCTAssertEqual(TypAugment.repairedDrawOrder(clean), clean)
    }
}
