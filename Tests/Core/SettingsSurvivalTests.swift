import XCTest
@testable import kmap

/// Whether a settings file survives this program being changed.
///
/// Two rules: every field that can be read is kept, and a file nothing could read is
/// never written over.
final class SettingsSurvivalTests: XCTestCase {

    /// A stored file in an older shape, shortened.
    private let stored = """
    {"outputDirectory":"/Users/x/Garmin/kmap",
     "defaultStyleID":"typ:borrowed",
     "familyIDs":{"child-region":6302,"parent-region":6311},
     "lastProfileID":"A",
     "profiles":[{"id":"A","name":"Handheld","choices":{"styleID":"typ:borrowed",
                  "contourInterval":20,"poiZoomSteps":3}},
                 {"id":"B","name":"Edge 1040","choices":{"styleID":"typ:borrowed"}}],
     "zoomPlans":[{"id":"p","name":"Mine","levelsID":"standard","shifts":{}}]}
    """

    func testOneUnreadableFieldCostsOnlyThatField() throws {
        let settings = try XCTUnwrap(SettingsStore.decode(Data(stored.utf8)),
                                     "the file should still be readable")
        XCTAssertEqual(settings.profiles.map(\.name), ["Handheld", "Edge 1040"])
        XCTAssertEqual(settings.familyIDs.count, 2)
        XCTAssertEqual(settings.defaultStyleID, "typ:borrowed")
        XCTAssertEqual(settings.outputDirectory, "/Users/x/Garmin/kmap")
        XCTAssertEqual(settings.lastProfileID, "A")
        // The fixture keeps the retired poiZoomSteps key: an unknown key is data to
        // step over, not a reason to fail.
        XCTAssertEqual(settings.profiles.first?.choices.contourInterval, 20)
    }

    /// A shift cannot become a window without a style to measure against, so a plan in
    /// the older shape comes back with the style's own.
    func testAPlanWrittenInAnOlderShapeStillReads() throws {
        let plan = try JSONDecoder().decode(
            ZoomPlan.self,
            from: Data(#"{"id":"p","name":"Mine","levelsID":"standard","shifts":{}}"#.utf8))
        XCTAssertEqual(plan.name, "Mine")
        XCTAssertEqual(plan.levelsID, "standard")
        XCTAssertFalse(plan.movesAnything)
    }

    /// A value of the wrong type is dropped alone, as an unknown field is.
    func testAFieldOfTheWrongTypeIsDroppedAlone() throws {
        let broken = """
        {"outputDirectory":"/Users/x/Garmin/kmap","downloadConnections":"lots",
         "profiles":[{"id":"A","name":"Kept","choices":{}}]}
        """
        let settings = try XCTUnwrap(SettingsStore.decode(Data(broken.utf8)))
        XCTAssertEqual(settings.profiles.map(\.name), ["Kept"])
        XCTAssertEqual(settings.outputDirectory, "/Users/x/Garmin/kmap")
        XCTAssertEqual(settings.downloadConnections,
                       Settings.default.downloadConnections, "back to the default")
    }

    /// Unreadable data decodes to `nil`; `SettingsStore.init` then renames the file
    /// rather than writing over it.
    func testRubbishReadsAsNothing() {
        XCTAssertNil(SettingsStore.decode(Data("not json at all".utf8)))
    }

    func testATestRunNeverWritesToTheRealSettings() {
        XCTAssertTrue(Paths.isATestRun)
        XCTAssertFalse(Paths.root.path.hasSuffix("/.kmap"),
                       "a test run must not point at the user's own directory")
        XCTAssertTrue(Paths.root.path.contains("kmap-tests"), Paths.root.path)
    }
}
