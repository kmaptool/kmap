import XCTest
@testable import kmap

/// Covers what travels when a borrowed look is ported onto kmap's own numbers.
final class StylePortTests: XCTestCase {

    /// Two rungs of one road, six pixels wide and one, painted the same.
    private let ladder = """
        ; -*- coding: UTF-8 -*-
        [_line]
        Type=0x11f14
        Xpm="0 0 2 0"
        "! c #E17272"
        "# c #606060"
        LineWidth=6
        BorderWidth=2
        String=0x04,Highway
        [end]

        [_line]
        Type=0x10e0b
        Xpm="0 0 2 0"
        "! c #E17272"
        "# c #606060"
        LineWidth=1
        BorderWidth=1
        String=0x04,Highway
        [end]
        """

    /// The block written for our number, without the section markers.
    private func block(_ text: String, code: Int) -> [String] {
        let lines = text.components(separatedBy: "\n")
        guard let at = lines.firstIndex(of: String(format: "Type=0x%02x", code)),
              let end = lines[at...].firstIndex(of: "[end]") else { return [] }
        return Array(lines[at..<end])
    }

    func testOurOneNumberWearsTheFarRungsWidthAndTheNearRungsPaint() {
        let theirs = TypSource.parse(ladder)
        let ported = StylePort.Ported(ours: 0x03, theirs: 0x11f14, kind: .line,
                                      meaning: "highway=primary", witnesses: 900,
                                      width: 1)
        let out = StylePort.typ(from: theirs, ported: [ported], familyID: nil,
                                productID: nil, codePage: nil)
        let drawn = block(out, code: 0x03)
        XCTAssertTrue(drawn.contains("LineWidth=1"))
        XCTAssertTrue(drawn.contains("BorderWidth=2"))
        XCTAssertTrue(drawn.contains("\"! c #E17272\""))
        XCTAssertTrue(drawn.contains("String=0x04,Highway"))
    }

    /// A number with no rung above it keeps its picture exactly as their file had it.
    /// Their style paints no ground: ours is still drawn, on its own levels. A day-only
    /// style gets a day-only ground, so night stays theirs to leave alone.
    func testAStyleWithNoGroundStillGetsTheLandDrawn() {
        let theirs = TypSource.parse(ladder)
        let out = StylePort.typ(from: theirs, ported: [], familyID: nil,
                                productID: nil, codePage: nil)
        let source = TypSource.parse(out)
        XCTAssertEqual(source.section(.polygon, 0x4b)?.xpm?.colours, [StylePort.paper])
        XCTAssertEqual(source.section(.polygon, 0x27)?.xpm?.colours, [StylePort.paper])
        XCTAssertEqual(source.section(.polygon, 0x32)?.xpm?.colours, [StylePort.seaBlue])
        let levels = Dictionary(source.drawOrder.map { ($0.code, $0.level) },
                                uniquingKeysWith: { a, _ in a })
        XCTAssertNotNil(levels[0x4b])
        XCTAssertNotNil(levels[0x27])
        XCTAssertNotEqual(levels[0x4b], levels[0x27], "the background keeps its own level")
    }

    /// A TYP has no night-only mode: a style made for the dark carries it in the day
    /// slot, and the ground under it must be dark too.
    func testADarkDayStyleGetsADarkGround() {
        let theirs = TypSource.parse("""
            [_polygon]
            Type=0x50
            Xpm="0 0 1 0"
            "1 c #204010"
            [end]

            [_polygon]
            Type=0x1c
            Xpm="0 0 1 0"
            "1 c #403020"
            [end]

            [_polygon]
            Type=0x13
            Xpm="0 0 1 0"
            "1 c #D0D0D0"
            [end]
            """)
        XCTAssertTrue(StylePort.drawsDark(theirs))
        XCTAssertFalse(StylePort.paintsNight(theirs))
        let out = StylePort.typ(from: theirs, ported: [], familyID: nil,
                                productID: nil, codePage: nil)
        let source = TypSource.parse(out)
        XCTAssertEqual(source.section(.polygon, 0x27)?.xpm?.colours, [StylePort.paperAtNight])
        XCTAssertEqual(source.section(.polygon, 0x32)?.xpm?.colours, [StylePort.seaBlueAtNight])
    }

    /// A style drawn for night too gets a ground with a night colour of its own.
    func testANightStyleGetsANightGround() {
        let theirs = TypSource.parse("""
            [_polygon]
            Type=0x50
            Xpm="0 0 2 0"
            "1 c #60B020"
            "2 c #204010"
            [end]

            [_polygon]
            Type=0x1c
            Xpm="0 0 2 0"
            "1 c #E9D8BD"
            "2 c #403020"
            [end]

            [_line]
            Type=0x06
            Xpm="0 0 1 0"
            "1 c #FFFFFF"
            [end]
            """)
        XCTAssertTrue(StylePort.paintsNight(theirs))
        let out = StylePort.typ(from: theirs, ported: [], familyID: nil,
                                productID: nil, codePage: nil)
        let source = TypSource.parse(out)
        XCTAssertEqual(source.section(.polygon, 0x27)?.xpm?.colours,
                       [StylePort.paper, StylePort.paperAtNight])
        XCTAssertEqual(source.section(.polygon, 0x32)?.xpm?.colours,
                       [StylePort.seaBlue, StylePort.seaBlueAtNight])
    }

    func testWithoutAFarRungThePictureIsCopiedUnchanged() {
        let theirs = TypSource.parse(ladder)
        let ported = StylePort.Ported(ours: 0x03, theirs: 0x11f14, kind: .line,
                                      meaning: "highway=primary", witnesses: 900,
                                      width: nil)
        let out = StylePort.typ(from: theirs, ported: [ported], familyID: nil,
                                productID: nil, codePage: nil)
        XCTAssertTrue(block(out, code: 0x03).contains("LineWidth=6"))
    }

    /// A width wider than the picture's own is not taken on: narrowing is the only
    /// thing a carried width is for.
    func testAWiderFarRungIsNotTakenOn() {
        let theirs = TypSource.parse(ladder)
        let ported = StylePort.Ported(ours: 0x03, theirs: 0x10e0b, kind: .line,
                                      meaning: "highway=primary", witnesses: 900,
                                      width: 9)
        let out = StylePort.typ(from: theirs, ported: [ported], familyID: nil,
                                productID: nil, codePage: nil)
        XCTAssertTrue(block(out, code: 0x03).contains("LineWidth=1"))
    }

    // MARK: Which of their pictures a number of ours takes

    /// Writes rule files into a throwaway directory and indexes them.
    private func index(lines: String = "", polygons: String = "",
                       points: String = "") throws -> RuleSetIndex {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("port-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        for (name, text) in [("lines", lines), ("polygons", polygons), ("points", points)]
        where !text.isEmpty {
            try text.write(to: dir.appendingPathComponent(name), atomically: true,
                           encoding: .utf8)
        }
        return try XCTUnwrap(RuleSetIndex.read(styleDirectory: dir))
    }

    /// A reserve lies on forest, so their forest was seen inside its outlines: the
    /// picture with nothing else under it wins, however often the forest was counted.
    func testAPictureTheMeaningOnlyLiesOnIsNotTakenForIt() throws {
        let rules = try index(polygons: "leisure=nature_reserve [0x16 resolution 18]\n")
        // The shares the real map gave: their forest was seen inside a few dozen reserve
        // outlines, a hundredth of a percent of the forest it draws.
        let evidence = [
            "leisure=nature_reserve": ["A0d": 119, "A52": 38],
            "natural=wood": ["A52": 139_104],
        ]
        let ported = StylePort.map(codesByTag: evidence, rules: rules,
                                   theirZooms: ["A0d": [23: 119], "A52": [24: 139_142]])
        XCTAssertEqual(ported.first(where: { $0.ours == 0x16 })?.theirs, 0x0d)
    }

    /// One number of ours for two meanings of theirs: the fill covering more ground
    /// wins the picture. Fields are few and wide, lawns many and small.
    func testASharedNumberWearsTheFillThatCoversMoreGround() throws {
        let rules = try index(polygons: """
            landuse=farmland [0x1c resolution 20]
            landuse=grass [0x1c resolution 19]
            """)
        let evidence = ["landuse=farmland": ["A24": 200], "landuse=grass": ["A17": 900]]
        let byCount = StylePort.map(codesByTag: evidence, rules: rules)
        XCTAssertEqual(byCount.first(where: { $0.ours == 0x1c })?.theirs, 0x17,
                       "with nothing but sightings the lawns win")
        let byGround = StylePort.map(
            codesByTag: evidence, rules: rules,
            theirAreas: ["landuse=farmland": ["A24": 5_000_000],
                         "landuse=grass": ["A17": 300_000]])
        XCTAssertEqual(byGround.first(where: { $0.ours == 0x1c })?.theirs, 0x24)
    }

    /// A `key=*` fallback is answered only by the values no rule of ours names: a
    /// hotel has its own number and never reaches `tourism=*`, so their hotel is no
    /// look for the tourist site.
    func testAFamilyFallbackIsAnsweredByTheValuesNoRuleNames() throws {
        let rules = try index(points: """
            tourism=attraction [0x2c0d resolution 24]
            tourism=hotel | tourism=guest_house [0x2b02 resolution 24]
            tourism=* & tourism!=no [0x2c0d resolution 24]
            """)
        let evidence = [
            "tourism=attraction": ["P6600": 200],
            "tourism=hotel": ["P2b02": 900],
            "tourism=guest_house": ["P2b02": 600],
            "tourism=yes": ["P6601": 20],
        ]
        let ported = StylePort.map(codesByTag: evidence, rules: rules)
        XCTAssertEqual(ported.first(where: { $0.ours == 0x2c0d })?.theirs, 0x6600)
        XCTAssertEqual(ported.first(where: { $0.ours == 0x2b02 })?.theirs, 0x2b02)
    }

    /// Where their code for one of the meanings is our number, the vocabularies agree
    /// on it, and that settles the number whatever the counts say.
    func testTheirOwnUseOfOurNumberSettlesIt() throws {
        let rules = try index(points: """
            tourism=museum [0x2c02 resolution 24]
            tourism=attraction & historic=* [0x2c02 resolution 24]
            """)
        let evidence = [
            "tourism=museum": ["P2c02": 100],
            "tourism=attraction": ["P6600": 300],
        ]
        let ported = StylePort.map(codesByTag: evidence, rules: rules)
        XCTAssertEqual(ported.first(where: { $0.ours == 0x2c02 })?.theirs, 0x2c02)
    }

    /// A point icon that shows nothing is their look for it: the name alone. It is
    /// ported, so the rule is not silenced for want of a picture.
    func testABlankPointIconIsStillTheirLook() throws {
        let rules = try index(points: "natural=bay & name=* [0x6503 resolution 20]\n")
        let theirs = TypSource.parse("""
            ; -*- coding: UTF-8 -*-
            [_point]
            Type=0x6503
            DayXpm="1 1 1 1"
            "! c none"
            "!"
            String=0x04,Bay
            [end]
            """)
        let ported = StylePort.map(codesByTag: ["natural=bay": ["P6503": 10]],
                                   rules: rules, theirTyp: theirs)
        XCTAssertEqual(ported.first(where: { $0.ours == 0x6503 })?.theirs, 0x6503)
    }

    /// A bay their map draws with a number their TYP never paints is the receiver's
    /// own label: our rule for it is declared unstyled, not silenced.
    func testWhatTheirMapLeavesToTheReceiverIsDeclaredUnstyled() throws {
        let rules = try index(points: "natural=bay & name=* [0x6503 resolution 20]\n")
        let theirs = TypSource.parse(ladder)
        let evidence = ["natural=bay": ["P6503": 10]]
        let ported = StylePort.map(codesByTag: evidence, rules: rules, theirTyp: theirs)
        let unstyled = StylePort.leftToTheDevice(codesByTag: evidence, rules: rules,
                                                 theirTyp: theirs, ported: ported)
        XCTAssertEqual(unstyled[.point], [0x6503])
        let out = StylePort.typ(from: theirs, ported: ported, familyID: nil,
                                productID: nil, codePage: nil, unstyled: unstyled)
        XCTAssertEqual(TypSource.parse(out).deliberatelyUnstyled[.point], [0x6503])
    }

    /// A class drawn at every zoom takes a width the overview can carry, and no class
    /// below it is left wider.
    func testNoRoadIsDrawnWiderThanTheClassAboveIt() throws {
        let rules = try index(lines: """
            highway=motorway [0x01 road_class=4 road_speed=7 resolution 14]
            highway=residential [0x06 road_class=0 road_speed=2 resolution 22]
            """)
        let theirs = TypSource.parse("""
            ; -*- coding: UTF-8 -*-
            [_line]
            Type=0x11f14
            Xpm="0 0 1 0"
            "! c #E17272"
            LineWidth=6
            [end]

            [_line]
            Type=0x10e0b
            Xpm="0 0 1 0"
            "! c #E17272"
            LineWidth=2
            [end]

            [_line]
            Type=0x12100
            Xpm="0 0 1 0"
            "! c #FFFFFF"
            LineWidth=4
            [end]
            """)
        let evidence = [
            "highway=motorway": ["L11f14": 900, "L10e0b": 600],
            "highway=residential": ["L12100": 5000],
        ]
        let ported = StylePort.map(codesByTag: evidence, rules: rules,
                                   theirZooms: ["L11f14": [24: 900], "L10e0b": [19: 600],
                                                "L12100": [24: 5000]],
                                   theirTyp: theirs)
        let motorway = ported.first { $0.ours == 0x01 }
        let residential = ported.first { $0.ours == 0x06 }
        XCTAssertEqual(motorway?.width, 2)
        XCTAssertEqual(residential?.width, 2)
    }

    /// A garden really is drawn as a park: a picture seen over hundreds of a meaning
    /// is its own, however small a fraction of that number's work it is.
    func testASharedPictureIsBelievedWhenItWasSeenOftenEnough() throws {
        let rules = try index(polygons: "leisure=garden [0x20 resolution 22]\n")
        let evidence = [
            "leisure=garden": ["A17": 465],
            "leisure=park": ["A17": 60_000],
        ]
        let ported = StylePort.map(codesByTag: evidence, rules: rules,
                                   theirZooms: ["A17": [24: 60_465]])
        XCTAssertEqual(ported.first(where: { $0.ours == 0x20 })?.theirs, 0x17)
    }
}
