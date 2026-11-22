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
            let end = lines[at...].firstIndex(of: "[end]")
        else { return [] }
        return Array(lines[at..<end])
    }

    func testOurOneNumberWearsTheFarRungsWidthAndTheNearRungsPaint() {
        let theirs = TypSource.parse(ladder)
        let ported = StylePort.Ported(
            ours: 0x03,
            theirs: 0x11f14,
            kind: .line,
            meaning: "highway=primary",
            witnesses: 900,
            width: 1
        )
        let out = StylePort.typ(
            from: theirs,
            ported: [ported],
            familyID: nil,
            productID: nil,
            codePage: nil
        )
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
        let out = StylePort.typ(
            from: theirs,
            ported: [],
            familyID: nil,
            productID: nil,
            codePage: nil
        )
        let source = TypSource.parse(out)
        XCTAssertEqual(source.section(.polygon, 0x4b)?.xpm?.colours, [StylePort.paper])
        XCTAssertEqual(source.section(.polygon, 0x27)?.xpm?.colours, [StylePort.paper])
        XCTAssertEqual(source.section(.polygon, 0x32)?.xpm?.colours, [StylePort.seaBlue])
        let levels = Dictionary(
            source.drawOrder.map { ($0.code, $0.level) },
            uniquingKeysWith: { a, _ in a }
        )
        XCTAssertNotNil(levels[0x4b])
        XCTAssertNotNil(levels[0x27])
        XCTAssertNotEqual(levels[0x4b], levels[0x27], "the background keeps its own level")
    }

    /// A TYP has no night-only mode: a style made for the dark carries it in the day
    /// slot, and the ground under it must be dark too.
    func testADarkDayStyleGetsADarkGround() {
        let theirs = TypSource.parse(
            """
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
            """
        )
        XCTAssertTrue(StylePort.drawsDark(theirs))
        XCTAssertFalse(StylePort.paintsNight(theirs))
        let out = StylePort.typ(
            from: theirs,
            ported: [],
            familyID: nil,
            productID: nil,
            codePage: nil
        )
        let source = TypSource.parse(out)
        XCTAssertEqual(source.section(.polygon, 0x27)?.xpm?.colours, [StylePort.paperAtNight])
        XCTAssertEqual(source.section(.polygon, 0x32)?.xpm?.colours, [StylePort.seaBlueAtNight])
    }

    /// A style drawn for night too gets a ground with a night colour of its own.
    func testANightStyleGetsANightGround() {
        let theirs = TypSource.parse(
            """
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
            """
        )
        XCTAssertTrue(StylePort.paintsNight(theirs))
        let out = StylePort.typ(
            from: theirs,
            ported: [],
            familyID: nil,
            productID: nil,
            codePage: nil
        )
        let source = TypSource.parse(out)
        XCTAssertEqual(
            source.section(.polygon, 0x27)?.xpm?.colours,
            [StylePort.paper, StylePort.paperAtNight]
        )
        XCTAssertEqual(
            source.section(.polygon, 0x32)?.xpm?.colours,
            [StylePort.seaBlue, StylePort.seaBlueAtNight]
        )
    }

    func testWithoutAFarRungThePictureIsCopiedUnchanged() {
        let theirs = TypSource.parse(ladder)
        let ported = StylePort.Ported(
            ours: 0x03,
            theirs: 0x11f14,
            kind: .line,
            meaning: "highway=primary",
            witnesses: 900,
            width: nil
        )
        let out = StylePort.typ(
            from: theirs,
            ported: [ported],
            familyID: nil,
            productID: nil,
            codePage: nil
        )
        XCTAssertTrue(block(out, code: 0x03).contains("LineWidth=6"))
    }

    /// A width wider than the picture's own is not taken on: narrowing is the only
    /// thing a carried width is for.
    func testAWiderFarRungIsNotTakenOn() {
        let theirs = TypSource.parse(ladder)
        let ported = StylePort.Ported(
            ours: 0x03,
            theirs: 0x10e0b,
            kind: .line,
            meaning: "highway=primary",
            witnesses: 900,
            width: 9
        )
        let out = StylePort.typ(
            from: theirs,
            ported: [ported],
            familyID: nil,
            productID: nil,
            codePage: nil
        )
        XCTAssertTrue(block(out, code: 0x03).contains("LineWidth=1"))
    }

    // MARK: Which of their pictures a number of ours takes

    /// Writes rule files into a throwaway directory and indexes them.
    private func index(
        lines: String = "",
        polygons: String = "",
        points: String = ""
    ) throws -> RuleSetIndex {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("port-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        for (name, text) in [("lines", lines), ("polygons", polygons), ("points", points)]
        where !text.isEmpty {
            try text.write(
                to: dir.appendingPathComponent(name),
                atomically: true,
                encoding: .utf8
            )
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
            "natural=wood": ["A52": 139_104]
        ]
        let ported = StylePort.map(
            codesByTag: evidence,
            rules: rules,
            theirZooms: ["A0d": [23: 119], "A52": [24: 139_142]]
        )
        XCTAssertEqual(ported.first(where: { $0.ours == 0x16 })?.theirs, 0x0d)
    }

    /// One number of ours for two meanings of theirs: the fill covering more ground
    /// wins the picture. Fields are few and wide, lawns many and small.
    func testASharedNumberWearsTheFillThatCoversMoreGround() throws {
        let rules = try index(
            polygons: """
                landuse=farmland [0x1c resolution 20]
                landuse=grass [0x1c resolution 19]
                """
        )
        let evidence = ["landuse=farmland": ["A24": 200], "landuse=grass": ["A17": 900]]
        let byCount = StylePort.map(codesByTag: evidence, rules: rules)
        XCTAssertEqual(
            byCount.first(where: { $0.ours == 0x1c })?.theirs,
            0x17,
            "with nothing but sightings the lawns win"
        )
        let byGround = StylePort.map(
            codesByTag: evidence,
            rules: rules,
            theirAreas: [
                "landuse=farmland": ["A24": 5_000_000],
                "landuse=grass": ["A17": 300_000]
            ]
        )
        XCTAssertEqual(byGround.first(where: { $0.ours == 0x1c })?.theirs, 0x24)
    }

    /// A `key=*` fallback is answered only by the values no rule of ours names: a
    /// hotel has its own number and never reaches `tourism=*`, so their hotel is no
    /// look for the tourist site.
    func testAFamilyFallbackIsAnsweredByTheValuesNoRuleNames() throws {
        let rules = try index(
            points: """
                tourism=attraction [0x2c0d resolution 24]
                tourism=hotel | tourism=guest_house [0x2b02 resolution 24]
                tourism=* & tourism!=no [0x2c0d resolution 24]
                """
        )
        let evidence = [
            "tourism=attraction": ["P6600": 200],
            "tourism=hotel": ["P2b02": 900],
            "tourism=guest_house": ["P2b02": 600],
            "tourism=yes": ["P6601": 20]
        ]
        let ported = StylePort.map(codesByTag: evidence, rules: rules)
        XCTAssertEqual(ported.first(where: { $0.ours == 0x2c0d })?.theirs, 0x6600)
        XCTAssertEqual(ported.first(where: { $0.ours == 0x2b02 })?.theirs, 0x2b02)
    }

    /// Where their code for one of the meanings is our number, the vocabularies agree
    /// on it, and that settles the number whatever the counts say: the other meaning
    /// has a number of its own to wear its picture on.
    func testTheirOwnUseOfOurNumberSettlesIt() throws {
        let rules = try index(
            points: """
                tourism=museum [0x2c02 resolution 24]
                tourism=attraction & historic=* [0x2c02 resolution 24]
                tourism=attraction [0x2c0d resolution 24]
                """
        )
        let evidence = [
            "tourism=museum": ["P2c02": 100],
            "tourism=attraction": ["P6600": 300]
        ]
        let ported = StylePort.map(codesByTag: evidence, rules: rules)
        XCTAssertEqual(ported.first(where: { $0.ours == 0x2c02 })?.theirs, 0x2c02)
    }

    /// A meaning our number alone draws has nowhere else to go: their 445 pitches are
    /// not painted as the 13 sports centres whose number happens to be ours.
    func testANamesakeDoesNotOutvoteAMeaningWithNoOtherNumber() throws {
        let rules = try index(
            polygons: """
                leisure=pitch [0x19 resolution 21]
                leisure=sports_centre [0x19 resolution 20]
                """
        )
        let evidence = [
            "leisure=sports_centre": ["A19": 13],
            "leisure=pitch": ["A41": 445]
        ]
        let ported = StylePort.map(codesByTag: evidence, rules: rules)
        XCTAssertEqual(ported.first(where: { $0.ours == 0x19 })?.theirs, 0x41)
        // With a number of its own to wear its picture on, the pitch leaves ours to the namesake.
        let housed = try index(
            polygons: """
                leisure=pitch [0x41 resolution 21]
                leisure=pitch & sport=* [0x19 resolution 21]
                leisure=sports_centre [0x19 resolution 20]
                """
        )
        XCTAssertEqual(
            StylePort.map(codesByTag: evidence, rules: housed).first(where: { $0.ours == 0x19 })?.theirs,
            0x19
        )
    }

    /// The picture that overrules the namesake takes the number, not a heavier one
    /// with nothing at stake: their marker for attractions has a number of ours.
    func testThePictureWithMostAtStakeTakesTheNumberFromTheNamesake() throws {
        let rules = try index(
            points: """
                tourism=museum [0x2c02 resolution 24]
                historic=ruins [0x2c02 resolution 24]
                tourism=attraction & historic=* [0x2c02 resolution 24]
                tourism=attraction [0x2c0d resolution 24]
                """
        )
        let evidence = [
            "tourism=museum": ["P2c02": 27],
            "historic=ruins": ["P661e": 31],
            "tourism=attraction": ["P6600": 240]
        ]
        let ported = StylePort.map(codesByTag: evidence, rules: rules)
        XCTAssertEqual(ported.first(where: { $0.ours == 0x2c02 })?.theirs, 0x661e)
        XCTAssertEqual(ported.first(where: { $0.ours == 0x2c0d })?.theirs, 0x6600)
    }

    /// Only what a rival alone stands to lose is weighed against the namesake: 400
    /// streams with a number of their own do not count, 10 weirs with none do not
    /// outweigh 30.
    func testOnlyTheMeaningsWithNoOtherNumberAreAtStake() throws {
        let rules = try index(
            lines: """
                waterway=stream [0x18 resolution 22]
                waterway=stream & intermittent=yes [0x26 resolution 22]
                waterway=weir [0x26 resolution 22]
                waterway=canal [0x26 resolution 22]
                """
        )
        let evidence = [
            "waterway=canal": ["L26": 30],
            "waterway=stream": ["L18": 400],
            "waterway=weir": ["L18": 10]
        ]
        let ported = StylePort.map(codesByTag: evidence, rules: rules)
        XCTAssertEqual(ported.first(where: { $0.ours == 0x26 })?.theirs, 0x26)
        let more = evidence.merging(["waterway=weir": ["L18": 31]]) { $1 }
        XCTAssertEqual(StylePort.map(codesByTag: more, rules: rules).first(where: { $0.ours == 0x26 })?.theirs, 0x18)
    }

    /// The layer over a building another rule claims takes the picture their map draws
    /// such buildings with, and none where the evidence found no such picture: neither
    /// their building's nor their amenity's lands on it by its tags.
    func testTheClaimedBuildingLayerTakesOnlyThePictureOfClaimedBuildings() throws {
        let rules = try index(
            polygons: """
                building=* & building!=no & (amenity=*) [0x36 resolution 24 continue]
                amenity=* & area!=no [0x23 resolution 22]
                building=* & building!=no [0x13 resolution 24]
                """
        )
        let plain = ["building=*": ["A13": 500], "amenity=*": ["A23": 60]]
        let without = StylePort.map(codesByTag: plain, rules: rules)
        XCTAssertEqual(without.first(where: { $0.ours == 0x13 })?.theirs, 0x13)
        XCTAssertNil(without.first { $0.ours == StyleCatalog.claimedBuildingCode })

        let theirLayer = StylePort.map(
            codesByTag: plain.merging([StylePort.claimedBuilding: ["A36": 40]]) { $1 },
            rules: rules
        )
        XCTAssertEqual(theirLayer.first(where: { $0.ours == StyleCatalog.claimedBuildingCode })?.theirs, 0x36)
        XCTAssertEqual(theirLayer.first(where: { $0.ours == 0x23 })?.theirs, 0x23)

        // Their map draws the building first: its picture is the layer's too.
        let buildingFirst = StylePort.map(
            codesByTag: plain.merging([StylePort.claimedBuilding: ["A13": 40]]) { $1 },
            rules: rules
        )
        XCTAssertEqual(buildingFirst.first(where: { $0.ours == StyleCatalog.claimedBuildingCode })?.theirs, 0x13)
        XCTAssertEqual(buildingFirst.first(where: { $0.ours == 0x13 })?.theirs, 0x13)
    }

    /// Claimed buildings are few among all their building code draws, and told from
    /// the sources: not the stray a few sightings of another meaning would be.
    func testAFewClaimedBuildingsAmongManyAreNoStray() throws {
        let rules = try index(
            polygons: """
                building=* & building!=no & (amenity=*) [0x36 resolution 24 continue]
                amenity=* & area!=no [0x23 resolution 22]
                building=* & building!=no [0x13 resolution 24]
                """
        )
        let theirs = TypSource.parse(
            """
            [_polygon]
            Type=0x13
            Xpm="0 0 1 0"
            "1 c #8B8BA0"
            [end]
            """
        )
        let ported = StylePort.map(
            codesByTag: ["building=*": ["A13": 5000], StylePort.claimedBuilding: ["A13": 40]],
            rules: rules,
            theirTyp: theirs
        )
        XCTAssertEqual(ported.first(where: { $0.ours == StyleCatalog.claimedBuildingCode })?.theirs, 0x13)
    }

    /// A building their map leaves to the receiver: the layer is not declared left to
    /// it, so the build takes the layer away and the building falls to its own number.
    func testALayerIsNeverLeftToTheReceiver() throws {
        let rules = try index(
            polygons: """
                building=* & building!=no & (amenity=*) [0x36 resolution 24 continue]
                amenity=* & area!=no [0x23 resolution 22]
                building=* & building!=no [0x13 resolution 24]
                """
        )
        let evidence = ["building=*": ["A13": 5000], StylePort.claimedBuilding: ["A13": 40]]
        let unstyled = StylePort.leftToTheDevice(
            codesByTag: evidence,
            rules: rules,
            theirTyp: TypSource.parse(ladder),
            ported: []
        )
        XCTAssertEqual(unstyled[.polygon], [0x13])
    }

    /// Their number equal to ours settles nothing where their number mostly draws a
    /// meaning ours does not carry: their 0x2f08 is a bus stop, our 0x2f08 a station.
    func testTheirNumberAgreesOnlyWhereItMeansTheSame() throws {
        let rules = try index(
            points: """
                highway=bus_stop [0x2f17 resolution 24]
                railway=station [0x2f08 resolution 22]
                railway=halt [0x2f08 resolution 23]
                amenity=bus_station [0x2f08 resolution 24]
                """
        )
        let evidence = [
            "highway=bus_stop": ["P2f08": 20_000],
            "amenity=bus_station": ["P2f08": 280],
            "railway=station": ["P2f17": 640],
            "railway=halt": ["P2f17": 620]
        ]
        let ported = StylePort.map(codesByTag: evidence, rules: rules)
        XCTAssertEqual(ported.first(where: { $0.ours == 0x2f08 })?.theirs, 0x2f17)
        XCTAssertEqual(ported.first(where: { $0.ours == 0x2f17 })?.theirs, 0x2f08)
    }

    /// 2 meanings drawn with 1 picture are counted together: rail and disused rail
    /// outweigh the tram that shares our number.
    func testOnePictureForSeveralMeaningsCountsThemAll() throws {
        let rules = try index(lines: "(railway=rail | railway=disused | railway=tram) [0x14 resolution 22]\n")
        let evidence = [
            "railway=disused": ["L12113": 400],
            "railway=rail": ["L12113": 12_000],
            "railway=tram": ["L10": 500]
        ]
        let ported = StylePort.map(codesByTag: evidence, rules: rules)
        let rail = try XCTUnwrap(ported.first { $0.ours == 0x14 })
        XCTAssertEqual(rail.theirs, 0x12113)
        XCTAssertEqual(rail.witnesses, 12_400)
    }

    /// The meanings drawn with 1 picture are summed before the contest, whatever their
    /// order: rail and subway outweigh light rail though light rail comes first.
    func testThePictureSeenMostWinsWhateverTheTagOrder() throws {
        let rules = try index(lines: "(railway=light_rail | railway=rail | railway=subway) [0x14 resolution 22]\n")
        let evidence = [
            "railway=light_rail": ["L12106": 6000],
            "railway=rail": ["L12103": 5000],
            "railway=subway": ["L12103": 3000]
        ]
        let rail = try XCTUnwrap(StylePort.map(codesByTag: evidence, rules: rules).first { $0.ours == 0x14 })
        XCTAssertEqual(rail.theirs, 0x12103)
        XCTAssertEqual(rail.witnesses, 8000)
        XCTAssertEqual(rail.meaning, "railway=rail")
    }

    /// Their number drawn mostly for a value only our `key=*` fallback catches still
    /// agrees with our number for that fallback, against a picture seen more whose
    /// meaning another number of ours takes whole.
    func testTheirNumberAgreesWithOurFallback() throws {
        let rules = try index(
            points: """
                tourism=viewpoint [0x2c04 resolution 24]
                tourism=viewpoint & historic=* [0x2c0d resolution 24]
                tourism=* & tourism!=no [0x2c0d resolution 24]
                """
        )
        let evidence = [
            "tourism=viewpoint": ["P6600": 400],
            "tourism=yes": ["P2c0d": 120]
        ]
        let ported = StylePort.map(codesByTag: evidence, rules: rules)
        XCTAssertEqual(ported.first(where: { $0.ours == 0x2c0d })?.theirs, 0x2c0d)
    }

    /// A grade split off the via ferrata wears the via ferrata's picture, not a further
    /// rung of their ladder.
    func testAGradeWearsItsParentsPicture() throws {
        let rules = try index(
            lines: """
                highway=via_ferrata & via_ferrata_scale ~ '3[+-]?' [0x3a resolution 22]
                highway=via_ferrata [0x37 resolution 22]
                """
        )
        let evidence = ["highway=via_ferrata": ["L1210c": 40, "L1210b": 30]]
        let ported = StylePort.map(
            codesByTag: evidence,
            rules: rules,
            theirZooms: ["L1210c": [24: 40], "L1210b": [22: 30]]
        )
        let parent = try XCTUnwrap(ported.first { $0.ours == 0x37 })
        XCTAssertEqual(ported.first { $0.ours == 0x3a }?.theirs, parent.theirs)
    }

    /// Their climber marks the ends of a via ferrata where their map marks none.
    func testTheirClimberMarksTheViaFerrataEnds() throws {
        let rules = try index(
            points: "sport=climbing [0x2c0e resolution 24]\nkmap:ferrata_end=yes [0x660a resolution 22 continue]\n"
        )
        let ported = StylePort.map(codesByTag: ["sport=climbing": ["P2c0e": 40]], rules: rules)
        XCTAssertEqual(ported.first { $0.ours == 0x660a }?.theirs, 0x2c0e)
    }

    /// A sports centre's picture that won our climbing number is no climber.
    func testASportsCentreIsNoClimberForTheEnds() throws {
        let rules = try index(
            points: """
                sport=climbing & leisure=sports_centre [0x2c0e resolution 24]
                kmap:ferrata_end=yes [0x660a resolution 22 continue]
                """
        )
        let ported = StylePort.map(codesByTag: ["leisure=sports_centre": ["P2d0a": 300]], rules: rules)
        XCTAssertNil(ported.first { $0.ours == 0x660a })
    }

    /// A point icon that shows nothing is their look for it: the name alone. It is
    /// ported, so the rule is not silenced for want of a picture.
    func testABlankPointIconIsStillTheirLook() throws {
        let rules = try index(points: "natural=bay & name=* [0x6503 resolution 20]\n")
        let theirs = TypSource.parse(
            """
            ; -*- coding: UTF-8 -*-
            [_point]
            Type=0x6503
            DayXpm="1 1 1 1"
            "! c none"
            "!"
            String=0x04,Bay
            [end]
            """
        )
        let ported = StylePort.map(
            codesByTag: ["natural=bay": ["P6503": 10]],
            rules: rules,
            theirTyp: theirs
        )
        XCTAssertEqual(ported.first(where: { $0.ours == 0x6503 })?.theirs, 0x6503)
    }

    /// Their map draws a building site as nothing. Ours stands on a number of its own
    /// that goes back to the industrial ground's where unpainted: the blank picture is
    /// ported, so the site is not drawn as an estate. A blank number beside a drawn one
    /// is a routing number, and no look.
    func testAMeaningTheirMapDrawsBlankIsDrawnBlank() throws {
        let rules = try index(
            lines: "highway=track [0x0a resolution 22]\n",
            polygons: """
                landuse=construction [0x34 resolution 21]
                landuse=industrial [0x0c resolution 20]
                """
        )
        let theirs = TypSource.parse(
            """
            [_polygon]
            Type=0x34
            Xpm="2 1 2 1"
            "a c none"
            "b c none"
            "ab"
            [end]
            [_polygon]
            Type=0x0c
            Xpm="0 0 1 0"
            "1 c #DBDBDB"
            [end]
            [_line]
            Type=0x0a
            Xpm="2 1 2 1"
            "a c none"
            "b c none"
            "ab"
            [end]
            [_line]
            Type=0x10e0a
            Xpm="0 0 1 0"
            "1 c #996600"
            LineWidth=2
            [end]
            """
        )
        let ported = StylePort.map(
            codesByTag: [
                "landuse=construction": ["A34": 40], "landuse=industrial": ["Ac": 90],
                "highway=track": ["La": 300, "L10e0a": 300]
            ],
            rules: rules,
            theirTyp: theirs
        )
        XCTAssertEqual(ported.first(where: { $0.kind == .polygon && $0.ours == 0x34 })?.theirs, 0x34)
        XCTAssertEqual(ported.first(where: { $0.kind == .polygon && $0.ours == 0x0c })?.theirs, 0x0c)
        XCTAssertEqual(ported.first(where: { $0.kind == .line && $0.ours == 0x0a })?.theirs, 0x10e0a)
    }

    /// The receiver draws by number. A living street their map leaves to it on the
    /// minor road's number is declared on that number, so the build sends our rule back.
    func testAMeaningLeftToTheReceiverKeepsTheNumberItIsDrawnBy() throws {
        let rules = try index(
            lines: """
                highway=living_street [0x10 road_class=0 road_speed=1 resolution 22]
                highway=residential [0x06 road_class=0 road_speed=2 resolution 22]
                """
        )
        let theirs = TypSource.parse(ladder)
        func unstyled(_ evidence: [String: [String: Int]]) -> Set<Int>? {
            StylePort.leftToTheDevice(codesByTag: evidence, rules: rules, theirTyp: theirs, ported: [])[.line]
        }
        XCTAssertEqual(unstyled(["highway=living_street": ["L6": 8]]), [0x06])
        // The number that drew it most decides, not a few sightings on another.
        XCTAssertEqual(unstyled(["highway=living_street": ["L6": 800, "L8": 3]]), [0x06])
        // Drawn by another number of the receiver's, ours is the nearest there is.
        XCTAssertEqual(unstyled(["highway=living_street": ["L7": 8]]), [0x10])
    }

    /// A bay their map draws with a number their TYP never paints is the receiver's
    /// own label: our rule for it is declared unstyled, not silenced.
    func testWhatTheirMapLeavesToTheReceiverIsDeclaredUnstyled() throws {
        let rules = try index(points: "natural=bay & name=* [0x6503 resolution 20]\n")
        let theirs = TypSource.parse(ladder)
        let evidence = ["natural=bay": ["P6503": 10]]
        let ported = StylePort.map(codesByTag: evidence, rules: rules, theirTyp: theirs)
        let unstyled = StylePort.leftToTheDevice(
            codesByTag: evidence,
            rules: rules,
            theirTyp: theirs,
            ported: ported
        )
        XCTAssertEqual(unstyled[.point], [0x6503])
        let out = StylePort.typ(
            from: theirs,
            ported: ported,
            familyID: nil,
            productID: nil,
            codePage: nil,
            unstyled: unstyled
        )
        XCTAssertEqual(TypSource.parse(out).deliberatelyUnstyled[.point], [0x6503])
    }

    /// A class drawn at every zoom takes a width the overview can carry, and no class
    /// below it is left wider.
    func testNoRoadIsDrawnWiderThanTheClassAboveIt() throws {
        let rules = try index(
            lines: """
                highway=motorway [0x01 road_class=4 road_speed=7 resolution 14]
                highway=residential [0x06 road_class=0 road_speed=2 resolution 22]
                """
        )
        let theirs = TypSource.parse(
            """
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
            """
        )
        let evidence = [
            "highway=motorway": ["L11f14": 900, "L10e0b": 600],
            "highway=residential": ["L12100": 5000]
        ]
        let ported = StylePort.map(
            codesByTag: evidence,
            rules: rules,
            theirZooms: [
                "L11f14": [24: 900], "L10e0b": [19: 600],
                "L12100": [24: 5000]
            ],
            theirTyp: theirs
        )
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
            "leisure=park": ["A17": 60_000]
        ]
        let ported = StylePort.map(
            codesByTag: evidence,
            rules: rules,
            theirZooms: ["A17": [24: 60_465]]
        )
        XCTAssertEqual(ported.first(where: { $0.ours == 0x20 })?.theirs, 0x17)
    }

    /// A picture ported onto a ground number is not drawn, the ground taking its own, so it
    /// is uncovered; the picture the ground does take is not.
    func testAPortOntoTheGroundLeavesItsPictureUncovered() throws {
        let rules = try index(polygons: "building=yes [0x13 resolution 24]\n")
        let theirs = TypSource.parse(
            """
            [_polygon]
            Type=0x13
            Xpm="0 0 1 0"
            "1 c #AA5500"
            [end]
            [_polygon]
            Type=0x4b
            Xpm="0 0 1 0"
            "1 c #FFFFEE"
            [end]
            """
        )
        let onGround = StylePort.Ported(
            ours: StylePort.backgroundCode,
            theirs: 0x13,
            kind: .polygon,
            meaning: "building=yes",
            witnesses: 50,
            width: nil
        )
        XCTAssertTrue(StylePort.landsOnGround(onGround))
        let uncovered = StylePort.uncovered(
            codesByTag: ["building=yes": ["A13": 50, "A4b": 40]],
            rules: rules,
            theirs: theirs,
            ported: StylePort.drawn([onGround])
        )
        XCTAssertTrue(StylePort.drawn([onGround]).isEmpty, "counted as the TYP draws it")
        XCTAssertEqual(uncovered.map(\.theirs), [0x13])
    }
}
