import XCTest

@testable import kmap

final class StagePreflightTests: XCTestCase {
    private func texts(_ build: BuildPipeline) -> [String] {
        build.log.snapshot().map(\.text)
    }

    // MARK: checkRecipe

    func testACodePageMkgmapDoesNotTakeIsRefusedBeforeTheDownload() {
        let build = PipelineFixture.pipeline { $0.codePage = 1 }
        XCTAssertThrowsError(try build.checkRecipe()) { error in
            guard case BuildError.unknownCodePage(1) = error else { return XCTFail("\(error)") }
        }
    }

    func testAFamilyIDOutsideTheRangeIsRefused() {
        let build = PipelineFixture.pipeline { $0.familyID = 70_000 }
        XCTAssertThrowsError(try build.checkRecipe()) { error in
            guard case BuildError.familyIDOutOfRange(70_000) = error else { return XCTFail("\(error)") }
        }
    }

    /// So no other map is given it.
    func testAGoodRecipeKeepsItsFamilyIDForTheMap() throws {
        let build = PipelineFixture.pipeline { $0.familyID = 6301 }
        let key = BuildRecipe.identityKey(build.recipe.regions)
        let before = build.settings.settings.familyIDs[key]
        defer { build.settings.update { $0.familyIDs[key] = before } }
        try build.checkRecipe()
        XCTAssertEqual(build.settings.settings.familyIDs[key], 6301)
    }

    // MARK: checkTools

    /// Other tests put a real mkgmap in the shared test root, so it is set aside here.
    func testAMissingToolStopsTheBuild() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["KMAP_ROOT"] != nil, "would move a real mkgmap aside")
        let mkgmap = Paths.tools.appendingPathComponent("mkgmap", isDirectory: true)
        if FileTools.exists(mkgmap) {
            let aside = Paths.tools.appendingPathComponent("mkgmap-aside-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.moveItem(at: mkgmap, to: aside)
            addTeardownBlock { try? FileManager.default.moveItem(at: aside, to: mkgmap) }
        }
        let build = PipelineFixture.pipeline()
        guard build.toolchain.findMkgmap() == nil else {
            throw XCTSkip("this machine has an mkgmap outside the test root")
        }
        do {
            try await build.checkTools()
            XCTFail("no tool was missing")
        } catch BuildError.missingTool {
        } catch {
            XCTFail("\(error)")
        }
    }

    // MARK: logRecipe

    func testTheLogSaysWhatTheBuildIsOf() {
        let build = PipelineFixture.pipeline()
        build.logRecipe()
        let lines = texts(build)
        for start in ["region:", "bbox:", "style:", "product:", "options:", "levels:", "work:", "output:"] {
            XCTAssertTrue(lines.contains { $0.hasPrefix(start) }, start)
        }
    }

    func testHouseNumbersWithoutTheIndexAreSaidToBeLeftOut() {
        let build = PipelineFixture.pipeline {
            $0.houseNumbers = true
            $0.searchIndex = false
        }
        build.logRecipe()
        XCTAssertTrue(texts(build).contains { $0.hasPrefix("house numbers left out") })
    }

    // MARK: sweepUnfinishedDownloads

    func testOldPartsOfDownloadsGoAndFreshOnesStay() throws {
        let build = PipelineFixture.pipeline()
        Paths.ensure(Paths.pbfCache)
        let old = Paths.pbfCache.appendingPathComponent("old-region.osm.pbf.part1")
        let fresh = Paths.pbfCache.appendingPathComponent("new-region.osm.pbf.part1")
        try FileTools.write(Data("old".utf8), to: old)
        try FileTools.write(Data("new".utf8), to: fresh)
        addTeardownBlock {
            FileTools.removeIfPresent(old)
            FileTools.removeIfPresent(fresh)
        }
        try FileDates.setModified(old, to: Date().addingTimeInterval(-30 * .day))

        build.sweepUnfinishedDownloads()

        XCTAssertFalse(FileTools.exists(old))
        XCTAssertTrue(FileTools.exists(fresh))
        XCTAssertTrue(texts(build).contains { $0.hasPrefix("cleared") })
    }

    func testNothingToSweepSaysNothing() {
        let build = PipelineFixture.pipeline()
        build.sweepUnfinishedDownloads()
        XCTAssertFalse(texts(build).contains { $0.hasPrefix("cleared") })
    }

    // MARK: warnOfLowSpace

    /// A full volume cannot be made on demand, so only this side is tested.
    func testRoomEnoughSaysNothing() throws {
        let work = try scratchFolder()
        let build = PipelineFixture.pipeline(workRoot: work)
        guard FileTools.freeSpaceBytes(at: work) > 8_000_000_000 else {
            throw XCTSkip("this volume is nearly full")
        }
        build.warnOfLowSpace()
        XCTAssertFalse(texts(build).contains { $0.contains("free on the volume") })
    }
}
