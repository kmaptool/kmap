import XCTest

@testable import kmap

final class WorkFolderTests: XCTestCase {
    /// Other maps' folders go after 3 days; unmarked, kept or held ones stay.
    func testWorkLeftByEarlierBuildsIsClearedButNotWhatIsNotKmaps() throws {
        let work = try scratchFolder()
        let build = PipelineFixture.pipeline(workRoot: work)
        let own = build.workDirectory
        try FileManager.default.createDirectory(
            at: own.appendingPathComponent("tiles"),
            withIntermediateDirectories: true
        )
        try Data(count: 10).write(to: own.appendingPathComponent("tiles/1.osm.pbf"))
        try Data().write(to: own.appendingPathComponent(BuildPipeline.workMarker))
        let old = Date().addingTimeInterval(-4 * 86_400)
        func folder(_ name: String, marked: Bool, at date: Date) throws -> URL {
            let url = work.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(count: 5).write(to: url.appendingPathComponent("tile.img"))
            if marked {
                let marker = url.appendingPathComponent(BuildPipeline.workMarker)
                try Data().write(to: marker)
                try FileDates.setModified(marker, to: date)
            }
            try FileDates.setModified(url, to: date)
            return url
        }
        _ = try folder("gone", marked: true, at: old)
        _ = try folder("fresh", marked: true, at: Date())
        let kept = try folder("kept", marked: true, at: old)
        try Data().write(to: kept.appendingPathComponent(BuildPipeline.keptMarker))
        _ = try folder("users-own", marked: false, at: old)
        let busy = try folder("busy", marked: true, at: old)
        Paths.ensure(Paths.locks)
        let held = try XCTUnwrap(HeldLock(trying: BuildPipeline.lock(BuildPipeline.workLockPrefix, for: busy)))

        try build.clearEarlierWork()
        withExtendedLifetime(held) {}

        XCTAssertEqual(
            Set(FileTools.contents(of: work).map(\.lastPathComponent)),
            [own.lastPathComponent, "fresh", "kept", "users-own", "busy"]
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: own.path), [BuildPipeline.workMarker])
    }

    /// The unmarked folder under a 3-region map's readable name goes with its next build.
    func testTheEarlierUnmarkedFolderOfABigSetIsCleared() throws {
        let build = PipelineFixture.pipeline(workRoot: try scratchFolder(), regions: 3)
        let earlier = build.recipe.workRoot.appendingPathComponent(build.recipe.areaSlug)
        XCTAssertNotEqual(build.recipe.areaSlug, build.recipe.slug)
        try FileManager.default.createDirectory(
            at: earlier.appendingPathComponent("tiles"),
            withIntermediateDirectories: true
        )
        try Data().write(to: earlier.appendingPathComponent("tiles/areas.list"))
        try build.clearEarlierWork()
        XCTAssertFalse(FileTools.exists(earlier))
    }

    /// Outside kmap's own work root only a folder kmap marked is cleared.
    func testAFolderOfTheUsersNamedAsTheWorkFolderIsLeftAlone() throws {
        let build = PipelineFixture.pipeline(workRoot: try scratchFolder())
        try FileManager.default.createDirectory(at: build.workDirectory, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: build.workDirectory.appendingPathComponent("notes.txt"))
        XCTAssertThrowsError(try build.clearEarlierWork())
        XCTAssertTrue(FileTools.exists(build.workDirectory.appendingPathComponent("notes.txt")))
    }

    /// Unmarked with kmap's files, or empty because cut short before its mark.
    func testAnUnmarkedFolderAsKmapLeavesItIsCleared() throws {
        let build = PipelineFixture.pipeline(workRoot: try scratchFolder())
        try FileManager.default.createDirectory(
            at: build.workDirectory.appendingPathComponent("tiles"),
            withIntermediateDirectories: true
        )
        try Data().write(to: build.workDirectory.appendingPathComponent("annotated.osm.pbf"))
        XCTAssertNoThrow(try build.clearEarlierWork())
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: build.workDirectory.path),
            [BuildPipeline.workMarker]
        )
        let empty = PipelineFixture.pipeline(workRoot: try scratchFolder())
        try FileManager.default.createDirectory(at: empty.workDirectory, withIntermediateDirectories: true)
        XCTAssertNoThrow(try empty.clearEarlierWork())
    }

    /// A hand-made mkgmap project named as the map is the user's.
    func testAProjectWithOtherToolsContoursIsLeftAlone() throws {
        let build = PipelineFixture.pipeline(workRoot: try scratchFolder())
        for name in ["style", "typ", "contours"] {
            try FileManager.default.createDirectory(
                at: build.workDirectory.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }
        let phyghtmap = build.workDirectory.appendingPathComponent(
            "contours/lon10.00_11.00lat47.00_48.00_srtm1v3.0.osm.pbf"
        )
        try Data().write(to: phyghtmap)
        XCTAssertThrowsError(try build.clearEarlierWork())
        XCTAssertTrue(FileTools.exists(phyghtmap))
        try Data().write(
            to: build.workDirectory.appendingPathComponent("contours/contour0001.osm.pbf.1a2b3c4d.partial")
        )
        XCTAssertNoThrow(try build.clearEarlierWork(), "with kmap's own, cut short too, it is kmap's")
    }

    /// Names kmap uses are not enough: something only kmap makes must be there.
    func testAFolderWithKmapsNamesButNothingKmapMadeIsLeftAlone() throws {
        let build = PipelineFixture.pipeline(workRoot: try scratchFolder())
        for name in ["tiles", "style"] {
            try FileManager.default.createDirectory(
                at: build.workDirectory.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }
        XCTAssertThrowsError(try build.clearEarlierWork())
        XCTAssertTrue(FileTools.exists(build.workDirectory.appendingPathComponent("tiles")))
    }
}
