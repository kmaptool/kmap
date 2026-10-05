import XCTest

@testable import kmap

/// The rule text a materialized style is shaped from: substitutions, and ladders fitted
/// to the levels a build draws at.
final class StyleCatalogRulesTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-catalog-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ text: String, to name: String) throws {
        try FileTools.write(text, to: directory.appendingPathComponent(name))
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    // MARK: Substitutions

    func testAnExactLineIsReplaced() throws {
        try write("a=b [0x10 resolution 24]\nc=d [0x20 resolution 24]\n", to: "points")
        let result = try StyleCatalog.applySubstitutions(
            "@@ points\n- a=b [0x10 resolution 24]\n+ a=b [0x11 resolution 24]\n",
            in: directory
        )
        XCTAssertEqual(result.applied, 1)
        XCTAssertTrue(result.missed.isEmpty)
        XCTAssertEqual(try read("points"), "a=b [0x11 resolution 24]\nc=d [0x20 resolution 24]\n")
    }

    func testASubstitutionThatNoLongerMatchesIsReportedNotGuessed() throws {
        let stock = "a=b [0x10 resolution 24]\n"
        try write(stock, to: "points")
        let result = try StyleCatalog.applySubstitutions(
            "@@ points\n- nothing=like-this [0x10 resolution 24]\n+ x=y [0x11 resolution 24]\n",
            in: directory
        )
        XCTAssertEqual(result.applied, 0)
        XCTAssertEqual(result.missed.count, 1)
        XCTAssertTrue(result.missed[0].hasPrefix("points:"))
        XCTAssertEqual(try read("points"), stock)
    }

    func testARuleTheHidePassSilencedIsBookkeepingNotAMiss() throws {
        try write("a=b [0x00 resolution 24] # kmap: hidden\n", to: "points")
        let result = try StyleCatalog.applySubstitutions(
            "@@ points\n- a=b [0x10 resolution 24]\n+ a=b [0x11 resolution 24]\n",
            in: directory
        )
        XCTAssertEqual(result.hidden, 1)
        XCTAssertTrue(result.missed.isEmpty)
    }

    func testARuleWhoseLabelWasTranslatedIsStillTheSameRule() throws {
        // The sheet is written against English labels and the pristine resolution; the
        // build has neither. The bare condition and the type it emits cannot drift.
        try write("ford=yes { name 'Brod' } [0x10 resolution 21]\n", to: "points")
        let result = try StyleCatalog.applySubstitutions(
            "@@ points\n- ford=yes { name 'Ford' } [0x10 resolution 22]\n"
                + "+ ford=yes { name 'Ford' } [0x11 resolution 22]\n",
            in: directory
        )
        XCTAssertEqual(result.applied, 1, "\(result.missed)")
        let text = try read("points")
        XCTAssertTrue(text.contains("[0x11"))
        XCTAssertTrue(text.contains("'Brod'"), "the build's own label stays")
        XCTAssertFalse(text.contains("[0x10"))
    }

    func testTheWholeConditionMustMatchNotAPrefixOfIt() throws {
        let stock = "highway=motorway & fast=yes [0x01 resolution 20]\n"
        try write(stock, to: "lines")
        let result = try StyleCatalog.applySubstitutions(
            "@@ lines\n- highway=motorway { name 'x' } [0x01 resolution 18]\n"
                + "+ highway=motorway { name 'x' } [0x02 resolution 18]\n",
            in: directory
        )
        XCTAssertEqual(result.applied, 0)
        XCTAssertEqual(try read("lines"), stock)
    }

    func testAFileTheStyleDoesNotHaveIsSkipped() throws {
        let result = try StyleCatalog.applySubstitutions(
            "@@ relations\n- a=b [0x10]\n+ a=b [0x11]\n",
            in: directory
        )
        XCTAssertEqual(result.applied, 0)
        XCTAssertTrue(result.missed.isEmpty)
    }

    // MARK: The ladder

    func testTheRungsAreEveryResolutionTheBuildDrawsAt() {
        for levels in [LevelsProfile.smooth, .standard] {
            let rungs = StyleCatalog.rungs(of: levels)
            XCTAssertEqual(rungs, rungs.sorted())
            XCTAssertEqual(rungs.last, GarminGrid.fullResolution, "the closest zoom is always there")
            XCTAssertGreaterThan(rungs.count, 3)
        }
    }

    func testABandBetweenTwoRungsMovesToTheNearestOne() throws {
        // A stroke pinned to 20-20 draws nothing on a ladder stepping 21, 19.
        try write("a=b [0x01 resolution 20-20]\n", to: "lines")
        XCTAssertEqual(try StyleCatalog.fitBands(to: [17, 19, 21, 24], in: directory), 1)
        XCTAssertEqual(try read("lines"), "a=b [0x01 resolution 19-19]\n", "a tie goes to the coarser rung")
    }

    func testABandThatAlreadyHoldsARungIsLeftAlone() throws {
        let stock = "a=b [0x01 resolution 20-22]\nc=d [0x02 resolution 24]\n"
        try write(stock, to: "lines")
        XCTAssertEqual(try StyleCatalog.fitBands(to: [17, 19, 21, 24], in: directory), 0)
        XCTAssertEqual(try read("lines"), stock)
    }

    func testWithoutALadderNothingIsFitted() throws {
        let stock = "a=b [0x01 resolution 20-20]\n"
        try write(stock, to: "lines")
        XCTAssertEqual(try StyleCatalog.fitBands(to: [], in: directory), 0)
        XCTAssertEqual(try read("lines"), stock)
    }

    func testTheCoarsestStrokeFollowsItsRuleOut() {
        // Two strokes above the rule that owns them; the rule draws out to 16, so the
        // stroke that reached 18 now reaches 16, and the road keeps its look.
        let ladder = """
            highway=trunk [0x100 resolution 22-24 continue]
            highway=trunk [0x101 resolution 18-21 continue]
            highway=trunk [0x02 resolution 16]
            """
        let reached = StyleCatalog.reachOfLadders(in: ladder).components(separatedBy: "\n")
        XCTAssertEqual(reached[1], "highway=trunk [0x101 resolution 16-21 continue]")
        XCTAssertEqual(reached[0], "highway=trunk [0x100 resolution 22-24 continue]", "only the coarsest")
    }

    func testALadderThatAlreadyReachesIsLeftAlone() {
        let ladder = """
            # highway=trunk [0x100 resolution 1-2] is a comment, not a rule
            highway=trunk [0x101 resolution 14-21 continue]
            highway=trunk [0x02 resolution 16]
            highway=primary [0x03 resolution 18]
            """
        XCTAssertEqual(StyleCatalog.reachOfLadders(in: ladder), ladder)
    }

    // MARK: A zoom plan's mark on the style's identity

    func testAPlanIsKnownByItsWindowsNotItsName() {
        let settings = SettingsStore()
        let catalog = StyleCatalog(settings: settings, toolchain: Toolchain(settings: settings))
        XCTAssertEqual(catalog.zoomTag(.asMeasured), "", "a plan that moves nothing leaves no mark")

        var one = ZoomPlan(id: "a", name: "First", levelsID: LevelsProfile.smooth.id)
        one.windows["trails"] = ZoomPlan.Window(finest: 2, coarsest: 0)
        one.windows["woodland"] = ZoomPlan.Window(finest: 1, coarsest: 3)
        var other = one
        other.id = "b"
        other.name = "Second"
        XCTAssertEqual(catalog.zoomTag(one), "+zoom-trails0-2,woodland1-3")
        XCTAssertEqual(catalog.zoomTag(one), catalog.zoomTag(other))
    }

    /// Rules fitted to 1 ladder's rungs are not the rules for another's.
    func testTheLadderIsPartOfWhatTheRulesAre() {
        let settings = SettingsStore()
        let catalog = StyleCatalog(settings: settings, toolchain: Toolchain(settings: settings))
        var smooth = StyleChoices()
        smooth.zoom = (.asMeasured, .smooth)
        var standard = StyleChoices()
        standard.zoom = (.asMeasured, .standard)
        XCTAssertNotEqual(catalog.materializedIdentity(smooth), catalog.materializedIdentity(standard))
    }

    /// A style folder reached through a link is copied as a folder: the build's own rule
    /// edits must not write through into the user's files. And a copy carrying another
    /// build's marker is said to be one.
    func testASnapshotIsARealCopyOfWhatWasPrepared() throws {
        let settings = SettingsStore()
        let catalog = StyleCatalog(settings: settings, toolchain: Toolchain(settings: settings))
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kmap-snap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileTools.write("highway=path [0x16 resolution 23]", to: real.appendingPathComponent("lines"))
        try FileTools.write("mine", to: real.appendingPathComponent("kmap-version"))
        let link = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let copy = root.appendingPathComponent("copy")
        XCTAssertTrue(try catalog.snapshot(link, to: copy, expecting: "mine"))
        XCTAssertEqual(FileTools.type(of: copy), FileAttributeType.typeDirectory)
        try FileTools.write("changed", to: copy.appendingPathComponent("lines"))
        XCTAssertEqual(
            try String(contentsOf: real.appendingPathComponent("lines"), encoding: .utf8),
            "highway=path [0x16 resolution 23]"
        )

        XCTAssertFalse(try catalog.snapshot(real, to: copy, expecting: "another build's"))
    }

    /// 2 names making 1 id would leave the second never buildable.
    func testTwoStylesOfOneIdAreToldApart() {
        func style(_ name: String) -> MapStyle {
            MapStyle(
                id: "dir:my-style",
                name: name,
                summary: "",
                origin: .builtin,
                styleDirectory: nil,
                typURL: nil,
                familyID: 6324,
                productID: 1
            )
        }
        XCTAssertEqual(
            StyleCatalog.distinctIDs([style("My Style"), style("my-style")]).map(\.id),
            ["dir:my-style", "dir:my-style-2"]
        )
        // A style already named the number given out is not shadowed.
        let own = MapStyle(
            id: "dir:my-style-2",
            name: "my-style-2",
            summary: "",
            origin: .builtin,
            styleDirectory: nil,
            typURL: nil,
            familyID: 6324,
            productID: 1
        )
        XCTAssertEqual(
            StyleCatalog.distinctIDs([style("My Style"), style("my-style"), own]).map(\.id),
            ["dir:my-style", "dir:my-style-3", "dir:my-style-2"]
        )
    }

    /// What a killed run left among the styles goes after a day; fresh ones stay.
    func testAbandonedStyleBuildsAreSweptAfterADay() throws {
        let styles = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "kmap-styles-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: styles) }
        for name in [".neutral-build-1A2B3C4D", ".base-build-1A2B3C4D", "unpack-1A2B3C4D", "kmap-base", "mine", ".lock"]
        {
            try FileManager.default.createDirectory(
                at: styles.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }
        StyleCatalog.removeAbandonedStaging(in: styles, now: Date())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: styles.path).count, 6)
        StyleCatalog.removeAbandonedStaging(in: styles, now: Date().addingTimeInterval(2 * 86_400))
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: styles.path)),
            ["kmap-base", "mine", ".lock"]
        )
    }

    /// A hidden rule is known by its own line, not by a comment quoting its condition or
    /// a hidden rule just below.
    func testAHiddenRuleIsKnownByItsOwnLine() {
        let text = """
            # place=isolated_dwelling & name=* was moved here
            place=isolated_dwelling & name=* [0x0b00 resolution 24]
            # office=government [0x3007 resolution 24]  # kmap: hidden
            """
        XCTAssertFalse(StyleCatalog.isHidden("place=isolated_dwelling & name=* [0x0b00 resolution 22]", in: text))
        XCTAssertTrue(StyleCatalog.isHidden("office=government [0x3008 resolution 24]", in: text))
        // A condition that only starts another's is another rule.
        let shops = "shop=car [0x2f07 resolution 22]\n# shop=car_repair [0x2f03 resolution 24]  # kmap: hidden"
        XCTAssertFalse(StyleCatalog.isHidden("shop=car [0x2f07 resolution 24]", in: shops))
    }
}
