import XCTest

@testable import kmap

/// The scan that keeps two builds from coming out as one file on a card.
///
/// It reads the output folder's dated build folders and reports every .img and .gmap name
/// in them, leaving out the folder being written — so a rebuild of the same map replaces
/// its own files instead of numbering itself upward day after day.
final class OutputNameScanTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-name-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func build(_ folder: String, holding files: [String]) throws -> URL {
        let dir = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in files {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }
        return dir
    }

    func testNamesFromNeighbouringBuildsAreSeen() throws {
        _ = try build(
            "2026-09-06_monaco",
            holding: [
                "kmap-osm-carto-1-regions.img",
                "build-info.txt"
            ]
        )
        let own = try build("2026-09-06_andorra", holding: [])
        let names = BuildPipeline.outputNames(under: root, excluding: own)
        XCTAssertEqual(
            names,
            ["kmap-osm-carto-1-regions.img"],
            "the .img is seen and the manifest beside it is not"
        )
    }

    func testABaseCampFolderIsSeenLikeACardFile() throws {
        // The .gmap is a folder, not a file, and sits beside the .img in the build folder.
        let other = try build("2026-09-06_monaco", holding: ["kmap-monaco-2026-09-06.img"])
        try FileManager.default.createDirectory(
            at: other.appendingPathComponent("kmap-monaco-2026-09-06.gmap"),
            withIntermediateDirectories: true
        )
        let own = try build("2026-09-06_andorra", holding: [])
        XCTAssertEqual(
            BuildPipeline.outputNames(under: root, excluding: own),
            ["kmap-monaco-2026-09-06.img", "kmap-monaco-2026-09-06.gmap"]
        )
    }

    func testTheBuildsOwnFolderIsLeftOut() throws {
        // A rebuild replaces its own files; counting them would number every rerun.
        let own = try build("2026-09-06_monaco", holding: ["kmap-osm-carto-1-regions.img"])
        XCTAssertTrue(BuildPipeline.outputNames(under: root, excluding: own).isEmpty)
    }

    func testAnEmptyOrMissingRootIsSimplyNoNames() throws {
        let own = root.appendingPathComponent("2026-09-06_monaco")
        XCTAssertTrue(BuildPipeline.outputNames(under: root, excluding: own).isEmpty)
        XCTAssertTrue(
            BuildPipeline.outputNames(
                under: root.appendingPathComponent("absent"),
                excluding: own
            ).isEmpty
        )
    }

    func testALooseImgDroppedInTheRootCountsToo() throws {
        // People move files around; a name is taken wherever it sits.
        try Data("x".utf8).write(to: root.appendingPathComponent("kmap-hand-moved.img"))
        let own = try build("2026-09-06_monaco", holding: [])
        XCTAssertEqual(
            BuildPipeline.outputNames(under: root, excluding: own),
            ["kmap-hand-moved.img"]
        )
    }

    func testCaseOfTheExtensionDoesNotHideAName() throws {
        _ = try build("old", holding: ["SHOUTY.IMG"])
        let own = try build("new", holding: [])
        XCTAssertEqual(BuildPipeline.outputNames(under: root, excluding: own), ["SHOUTY.IMG"])
    }
}
