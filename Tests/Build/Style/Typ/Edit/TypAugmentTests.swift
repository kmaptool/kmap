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
        try FileTools.write(text, to: url)
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
        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8),
            before,
            "and the original is byte for byte what it was"
        )
        XCTAssertNotNil(result.refusal, "silently building something else would be worse")
        XCTAssertEqual(result.added, [])
    }

    /// A copy belongs to the build that asked for it and carries that build's theme, so a
    /// build asking for another theme is not handed it.
    func testTheCopyGoesWhereTheBuildAsksForIt() throws {
        let url = try write(TypFixture.source)
        let scratch = folder.appendingPathComponent("build", isDirectory: true)

        let result = try XCTUnwrap(TypAugment.prepare(url, theme: .day, into: scratch))

        XCTAssertEqual(
            result.url.deletingLastPathComponent().standardizedFileURL,
            scratch.standardizedFileURL
        )
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
            XCTAssertTrue(
                before.codes(kind).isSubset(of: after.codes(kind)),
                "\(kind.rawValue) sections went missing"
            )
        }
        XCTAssertEqual(after.familyID, before.familyID)
        XCTAssertEqual(after.codePage, before.codePage)
        XCTAssertEqual(after.drawOrder.count, before.drawOrder.count)
        XCTAssertTrue(
            try String(contentsOf: result.url, encoding: .utf8)
                .hasPrefix(TypFixture.source.trimmingCharacters(in: .newlines)),
            "the original text must come first and unchanged"
        )
    }

    // MARK: What does not get added

    /// A style that already draws both keeps its own sections; nothing is appended.
    func testAStyleThatAlreadyDrawsThemIsLeftCompletelyAlone() throws {
        let mine =
            TypFixture.source + """

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
        let theirs =
            TypFixture.source + """

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
        XCTAssertTrue(
            TypAugment.routableLines.contains(moved),
            "a link the receiver will not route on is not a repair link"
        )

        let after = TypSource.parse(try String(contentsOf: result.url, encoding: .utf8))
        XCTAssertEqual(
            after.section(.line, 0x0d)?.englishLabel,
            "Pedestrian street",
            "their own drawing is untouched"
        )
        XCTAssertEqual(
            after.section(.line, moved)?.englishLabel,
            TypAugment.repairLabel,
            "the mark is drawn where it moved"
        )
    }

    /// The number has to be free twice over: unused by the borrowed style, and unused by
    /// kmap's rules — or every footway on it would wear the link's dashes.
    func testTheLinkMovesPastTheNumbersOurOwnRulesEmit() throws {
        let theirs =
            TypFixture.source + """

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
        try used.joined(separator: "\n").write(
            to: rules.appendingPathComponent("lines"),
            atomically: true,
            encoding: .utf8
        )

        let result = try XCTUnwrap(TypAugment.prepare(try write(theirs), rules: rules))
        XCTAssertEqual(
            result.moved[.line]?[0x0d],
            0x13,
            "the one routing number nothing else means"
        )
    }

    /// A style that draws the link but not the mark keeps its own link.
    func testOnlyWhatIsMissingIsAdded() throws {
        // Labelled as kmap labels its own: this is the repair link, drawn the style's
        // own way, and it is left alone.
        let half =
            TypFixture.source + """

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
        XCTAssertEqual(
            after.section(.line, 0x0d)?.englishLabel,
            "Repaired link",
            "the style's own link must survive"
        )
        XCTAssertNotNil(after.section(.point, 0x660b))
    }

    // MARK: The file the user owns

    func testTheOriginalIsNeverWrittenTo() throws {
        let url = try write(TypFixture.source)
        let before = try Data(contentsOf: url)
        let result = try XCTUnwrap(TypAugment.prepare(url))

        XCTAssertNotEqual(result.url, url)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertFalse(
            TypLibrary.mayWrite(to: result.url),
            "the augmented copy is a build artefact, not a library entry"
        )
    }

    // MARK: What cannot be done

    /// A compiled TYP has no text to append to; the build uses it and reports the reason.
    func testACompiledTypIsBuiltWithAnywayAndTheReasonIsGiven() throws {
        var bytes = [UInt8](repeating: 0, count: 0x60)
        bytes[0] = 0x5B
        for (i, b) in Array("GARMIN TYP".utf8).enumerated() { bytes[2 + i] = b }
        bytes[0x2F] = 1
        let url = folder.appendingPathComponent("compiled.typ")
        try FileTools.write(Data(bytes), to: url)

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
            XCTAssertNotNil(
                TypSource.parse(StyleAssets.repairMarks)
                    .section(entry.kind, entry.code),
                TypeMeaning.hex(entry.code)
            )
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
        XCTAssertTrue(
            mended.contains("\"1 c #FF00FF\"  ; a comment here is fine"),
            "only the draw-order table is touched"
        )
    }

    /// A file with nothing to mend comes back as it was, byte for byte.
    func testAnUndamagedTypIsNotRewritten() {
        let clean = "[_drawOrder]\nType=0x16,1\n[end]\n"
        XCTAssertEqual(TypAugment.repairedDrawOrder(clean), clean)
    }

    // MARK: A settlement, the wood drawn across it and the field drawn round it

    /// A TYP with a ground, a wood floor, a forest, an orchard, grass and 2 settlement
    /// tints, in the order a style usually has them: the tints over all that grows.
    private static let settled = """
        [_id]
        FID=1
        ProductCode=1
        CodePage=1252
        [end]

        [_drawOrder]
        Type=0x027,1
        Type=0x059,2
        Type=0x04e,3
        Type=0x050,3
        Type=0x055,3
        Type=0x003,4
        Type=0x010,4
        Type=0x01a,4
        Type=0x013,5
        [end]

        [_polygon]
        Type=0x10
        Xpm="0 0 2 0"
        "1 c #E9E5DD"
        "2 c #404040"
        String=0x00,Residential
        [end]

        [_polygon]
        Type=0x59
        Xpm="0 0 2 0"
        "1 c #B8DCA0"
        "2 c #1E401E"
        String=0x00,Woodland
        [end]
        """

    private func levels(in text: String) -> [Int: Int] {
        Dictionary(uniqueKeysWithValues: TypSource.parse(text).drawOrder.map { ($0.code, $0.level) })
    }

    /// Grass stays under the tints; the tints go right over it, the wood and the orchard
    /// over the tints in the order they had, and what was over the tints stays over all.
    func testWoodsGoOverTheSettlementTintsAndOpenGroundStaysUnder() throws {
        let url = try write(Self.settled)
        let scratch = folder.appendingPathComponent("build", isDirectory: true)

        let result = try XCTUnwrap(TypAugment.prepare(url, into: scratch))
        let order = levels(in: try String(contentsOf: result.url, encoding: .utf8))

        XCTAssertTrue(result.woodsLaidOver)
        XCTAssertEqual(order[0x27], 1)
        XCTAssertEqual(order[0x55], 3, "a meadow does not move")
        XCTAssertEqual(order[0x10], 4, "the tints right over it")
        XCTAssertEqual(order[0x03], 4)
        XCTAssertEqual(order[0x59], 5, "the wood's floor over the tints")
        XCTAssertEqual(order[0x50], 6, "and its symbols over the floor, as they were")
        XCTAssertEqual(order[0x4e], 6, "an orchard with them")
        XCTAssertEqual(order[0x1a], 7, "a cemetery stays over the wood")
        XCTAssertEqual(order[0x13], 8)
        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8),
            Self.settled,
            "the file the user owns is not written to"
        )
    }

    /// A style that already has the 3 in that order is not touched.
    func testATableAlreadyInThatOrderIsLeftAlone() {
        let arranged = [
            "[_drawOrder]", "Type=0x027,1", "Type=0x055,2", "Type=0x010,3", "Type=0x059,4", "Type=0x050,5",
            "[end]"
        ]
        var lines = arranged
        XCTAssertFalse(
            TypEdit.layWoodsOverTints(&lines, tints: [0x10, 0x03], woods: [0x59, 0x50], covers: [0x55])
        )
        XCTAssertEqual(lines, arranged)
    }

    /// Tints under everything that grows are lifted over the open ground and no further.
    func testTintsUnderOpenGroundComeUpOverIt() {
        var lines = [
            "[_drawOrder]", "Type=0x027,1", "Type=0x010,2", "Type=0x059,3", "Type=0x050,4", "Type=0x055,4",
            "Type=0x056,5", "[end]"
        ]
        XCTAssertTrue(TypEdit.layWoodsOverTints(&lines, tints: [0x10], woods: [0x59, 0x50], covers: [0x55]))
        let order = levels(in: lines.joined(separator: "\n"))
        XCTAssertEqual(order[0x55], 4)
        XCTAssertEqual(order[0x10], 5)
        XCTAssertEqual(order[0x59], 6)
        XCTAssertEqual(order[0x50], 7)
        XCTAssertEqual(order[0x56], 8, "bare rock stays over the wood")
    }

    /// A TYP from Windows split at LF keeps a CR on each line: the table is still found.
    func testATableWithCarriageReturnsIsStillRead() {
        var lines = ["[_drawOrder]", "Type=0x027,1", "Type=0x059,2", "Type=0x010,3", "[end]"].map { $0 + "\r" }
        XCTAssertTrue(TypEdit.layWoodsOverTints(&lines, tints: [0x10], woods: [0x59], covers: [0x55]))
    }

    /// With no open ground in the table the 2 go back where the lower of them was.
    func testWithoutOpenGroundTheWoodStillGoesOverTheTint() {
        var lines = ["[_drawOrder]", "Type=0x027,1", "Type=0x059,2", "Type=0x010,3", "Type=0x013,4", "[end]"]
        XCTAssertTrue(TypEdit.layWoodsOverTints(&lines, tints: [0x10], woods: [0x59], covers: [0x55]))
        let order = levels(in: lines.joined(separator: "\n"))
        XCTAssertEqual(order[0x27], 1)
        XCTAssertEqual(order[0x10], 2)
        XCTAssertEqual(order[0x59], 3)
        XCTAssertEqual(order[0x13], 6)
    }

    /// No wood or no tint: the table is not touched.
    func testATableWithoutAWoodOrATintIsNotTouched() {
        let bare = ["[_drawOrder]", "Type=0x027,1", "Type=0x010,2", "[end]"]
        var lines = bare
        XCTAssertFalse(TypEdit.layWoodsOverTints(&lines, tints: [0x10], woods: [0x59], covers: [0x55]))
        XCTAssertEqual(lines, bare)
    }

    // MARK: A glade and the wood it is drawn across

    /// With the mkgmap that hands them out, each kind of open ground the style draws
    /// gets a copy on a free number, on a level right over the woods, and the option
    /// names the pairs and the woods.
    func testOpenGroundGetsACopyOverTheWoods() throws {
        let meadow =
            Self.settled
            + "\n\n[_polygon]\nType=0x55\nXpm=\"0 0 2 0\"\n\"1 c #D0E8B0\"\n\"2 c #304030\"\n"
            + "String=0x00,Grassland\n[end]\n"
        let url = try write(meadow)
        let scratch = folder.appendingPathComponent("build", isDirectory: true)

        let result = try XCTUnwrap(TypAugment.prepare(url, into: scratch, liftingOpenGround: true))
        let text = try String(contentsOf: result.url, encoding: .utf8)
        let source = TypSource.parse(text)
        let order = levels(in: text)

        XCTAssertEqual(result.shapeLift, "--x-shape-lift=0x55>0x5c:0x59,0x50")
        XCTAssertEqual(source.section(.polygon, 0x5c)?.englishLabel, "Grassland", "the same picture")
        XCTAssertEqual(order[0x55], 3, "the meadow itself stays under the tints")
        XCTAssertEqual(order[0x50], 6)
        XCTAssertEqual(order[0x5c], 8, "its copy over the woods, a step above the floor copies")
        XCTAssertEqual(order[0x1a], 9, "and what was over the woods over the copy too")
    }

    /// Without that mkgmap nothing is added: the order alone decides, and a glade
    /// drawn across a wood lies under it.
    func testWithoutTheLiftNoCopyIsAdded() throws {
        let meadow =
            Self.settled
            + "\n\n[_polygon]\nType=0x55\nXpm=\"0 0 2 0\"\n\"1 c #D0E8B0\"\n\"2 c #304030\"\n"
            + "String=0x00,Grassland\n[end]\n"
        let url = try write(meadow)
        let scratch = folder.appendingPathComponent("build", isDirectory: true)

        let result = try XCTUnwrap(TypAugment.prepare(url, into: scratch))
        let source = TypSource.parse(try String(contentsOf: result.url, encoding: .utf8))

        XCTAssertNil(result.shapeLift)
        XCTAssertNil(source.section(.polygon, 0x5c))
        XCTAssertTrue(result.woodsLaidOver, "the order is still put right")
    }

    /// The copies stand on the steps asked for, and everything over the woods moves up.
    func testCopiesStandOnTheirStepsOverTheWoods() {
        var lines = [
            "[_drawOrder]", "Type=0x027,1", "Type=0x059,2", "Type=0x050,3", "Type=0x013,4", "[end]"
        ]
        XCTAssertTrue(TypEdit.layOverWoods(&lines, lifted: [(0x5c, 0), (0x5d, 1)], woods: [0x59, 0x50]))
        let order = levels(in: lines.joined(separator: "\n"))
        XCTAssertEqual(order[0x50], 3)
        XCTAssertEqual(order[0x5c], 4)
        XCTAssertEqual(order[0x5d], 5)
        XCTAssertEqual(order[0x13], 6)
    }
}
