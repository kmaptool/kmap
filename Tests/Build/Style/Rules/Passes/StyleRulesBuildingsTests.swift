import XCTest

@testable import kmap

/// A building another rule claims first gets a layer of its own, which a palette may paint.
final class StyleRulesBuildingsTests: XCTestCase {
    private static let polygons = """
        # a comment naming leisure=park [0x17]
        amenity=parking & area!=no [0x05 resolution 22]
        shop=* & shop!=no {add name='${shop}'} [0x08 resolution 22]
        historic=castle | tourism=museum [0x22 resolution 21]
        natural=water & mkgmap:mp_created=true [0x3c resolution 20 continue]
        landuse=forest [0x50 resolution 18]
        building=* & building!=no [0x13 resolution 24]
        man_made=pier [0x25 resolution 22]
        """

    private func directory(polygons: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claimed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try polygons.write(to: dir.appendingPathComponent("polygons"), atomically: true, encoding: .utf8)
        return dir
    }

    private var catalog: StyleCatalog {
        let settings = SettingsStore()
        return StyleCatalog(settings: settings, toolchain: Toolchain(settings: settings))
    }

    /// The keys are the ones a typed rule above the building rule draws by: not a
    /// comment's, not a rule's that lets the building rule fire, not one standing below.
    func testTheLayerNamesEveryKeyARuleAboveTheBuildingRuleDrawsBy() {
        XCTAssertEqual(
            StyleCatalog.claimedBuildingRule(for: Self.polygons),
            "building=* & building!=no & (amenity=* | historic=* | landuse=* | shop=* | tourism=*)"
                + " [0x36 resolution 24 continue]"
        )
    }

    func testAFileWithoutTheStockBuildingRuleGetsNoLayer() {
        XCTAssertNil(StyleCatalog.claimedBuildingRule(for: "amenity=parking [0x05 resolution 22]\n"))
    }

    /// At the top, so no rule answers first, and once however often the pass runs.
    func testTheLayerGoesInOnceAheadOfEveryRule() throws {
        let dir = try directory(polygons: Self.polygons)
        try catalog.addClaimedBuildingLayer(in: dir, log: Log())
        try catalog.addClaimedBuildingLayer(in: dir, log: Log())
        let text = try String(contentsOf: dir.appendingPathComponent("polygons"), encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "[0x36").count, 2)
        XCTAssertTrue(text.hasPrefix(StyleCatalog.claimedBuildingMarker))
        XCTAssertTrue(text.hasSuffix(Self.polygons))
    }

    func testAStyleWithoutTheStockBuildingRuleIsWarnedAbout() throws {
        let dir = try directory(polygons: "amenity=parking [0x05 resolution 22]\n")
        let log = Log()
        try catalog.addClaimedBuildingLayer(in: dir, log: log)
        XCTAssertTrue(log.snapshot().contains { $0.severity == .warn })
        XCTAssertEqual(
            try String(contentsOf: dir.appendingPathComponent("polygons"), encoding: .utf8),
            "amenity=parking [0x05 resolution 22]\n"
        )
    }

    /// A palette with no picture for the layer loses it, and draws as it did without it.
    func testTheLayerGoesWhereThePaletteHasNoPictureForIt() throws {
        let dir = try directory(polygons: Self.polygons)
        try catalog.addClaimedBuildingLayer(in: dir, log: Log())
        let building = TypSource.parse(
            """
            [_polygon]
            Type=0x13
            Xpm="0 0 1 0"
            "! c #D9D0C9"
            [end]
            """
        )
        try StyleCatalog.keepTheOldNumberWherePaletteIsSilent(in: dir, palette: building, log: Log())
        let text = try String(contentsOf: dir.appendingPathComponent("polygons"), encoding: .utf8)
        XCTAssertFalse(text.contains("[0x36"), text)
        XCTAssertTrue(text.contains("building=* & building!=no [0x13 resolution 24]"))
    }

    func testTheLayerStaysWhereThePalettePaintsIt() throws {
        let dir = try directory(polygons: Self.polygons)
        try catalog.addClaimedBuildingLayer(in: dir, log: Log())
        let painted = TypSource.parse(
            """
            [_polygon]
            Type=0x36
            Xpm="0 0 1 0"
            "! c #D9D0C9"
            [end]
            """
        )
        try StyleCatalog.keepTheOldNumberWherePaletteIsSilent(in: dir, palette: painted, log: Log())
        XCTAssertTrue(
            try String(contentsOf: dir.appendingPathComponent("polygons"), encoding: .utf8).contains(
                "[0x36 resolution 24 continue]"
            )
        )
    }
}
