import XCTest

@testable import kmap

/// The BaseCamp folder: what mkgmap is asked for, and how the folder it wrote is found.
final class GmapBundleTests: XCTestCase {
    private var pipeline: BuildPipeline!
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-gmap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let region = Region(
            id: "test/here",
            name: "Here",
            parentID: nil,
            pbfURL: nil,
            bbox: BBox(minLon: 7.3, minLat: 43.7, maxLon: 7.5, maxLat: 43.8),
            boxes: []
        )
        let style = MapStyle(
            id: "plain",
            name: "Plain",
            summary: "",
            origin: .builtin,
            styleDirectory: nil,
            typURL: nil,
            familyID: 6300,
            productID: 1
        )
        var recipe = BuildRecipe(region: region, style: style, outputDirectory: scratch)
        recipe.familyID = 6307
        recipe.demLayer = false
        recipe.searchIndex = true
        let settings = SettingsStore()
        let toolchain = Toolchain(settings: settings)
        pipeline = BuildPipeline(
            recipe: recipe,
            settings: settings,
            toolchain: toolchain,
            styles: StyleCatalog(settings: settings, toolchain: toolchain)
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func folder(_ path: String) throws -> URL {
        let url = scratch.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: The arguments

    func testTheGmapiRunNamesTheOverviewAndAsksForProfiles() {
        let options = pipeline.gmapOptions()
        XCTAssertEqual(
            options,
            ["--overview-mapname=63070000", "--overview-mapnumber=63070000", "--show-profiles=1"],
            "no DEM layer, so no relief for the overview"
        )
    }

    func testACombineRunIsTheModeThenTheIdentityThenTheInputs() throws {
        let java = JavaRuntime(path: "/usr/bin/java", version: "21", options: [])
        let tiles = [scratch.appendingPathComponent("63070001.img"), scratch.appendingPathComponent("63070002.img")]
        let typ = scratch.appendingPathComponent("plain.typ")
        try FileTools.write(Data("typ".utf8), to: typ)
        let arguments = pipeline.combineArguments(
            java: java,
            mkgmap: URL(fileURLWithPath: "/tools/mkgmap.jar"),
            mode: "--gmapi",
            areaName: "here",
            outputDir: scratch,
            options: ["--show-profiles=1"],
            inputs: tiles,
            typ: typ
        )
        XCTAssertEqual(arguments.firstIndex(of: "--gmapi"), arguments.firstIndex(of: "/tools/mkgmap.jar")! + 1)
        XCTAssertTrue(arguments.contains("--family-id=6307"))
        XCTAssertTrue(
            arguments.contains { $0.hasPrefix("--product-version=") },
            "the version the desktop programs list the map under"
        )
        XCTAssertTrue(arguments.contains("--output-dir=\(scratch.path)"))
        XCTAssertTrue(arguments.contains("--show-profiles=1"))
        XCTAssertTrue(arguments.contains("--index"), "the search index is rebuilt over the finished tiles")
        // Inputs go last, the TYP after them; a TYP that is not on disk is left out.
        XCTAssertEqual(arguments.suffix(3), [tiles[0].path, tiles[1].path, typ.path])
        let without = pipeline.combineArguments(
            java: java,
            mkgmap: URL(fileURLWithPath: "/tools/mkgmap.jar"),
            mode: "--gmapsupp",
            areaName: "here",
            outputDir: scratch,
            inputs: tiles,
            typ: scratch.appendingPathComponent("absent.typ")
        )
        XCTAssertEqual(without.last, tiles[1].path)
        XCTAssertTrue(without.contains("--gmapsupp"))
        XCTAssertFalse(without.contains("--gmapi"))
    }

    /// The compile alone builds no search index, which the packing run builds over every
    /// tile anyway, and says each thing once.
    func testTheCompileRunLeavesTheIndexToThePackingRun() throws {
        let options = try pipeline.mkgmapOptions(name: "here", outputDir: scratch, tileCount: 2, gmapsupp: false)
        XCTAssertFalse(options.contains("--index"))
        XCTAssertTrue(options.contains("--poi-address"), "the tiles still carry their addresses")
        XCTAssertEqual(options.filter { $0.hasPrefix("--code-page=") }.count, 1)
        let packed = try pipeline.mkgmapOptions(name: "here", outputDir: scratch, tileCount: 2, gmapsupp: true)
        XCTAssertTrue(packed.contains("--index"))
    }

    /// House numbers are found only through address search: with no index they are left
    /// out, whatever the recipe says.
    func testHouseNumbersGoWithTheIndexOnly() throws {
        var recipe = pipeline.recipe
        recipe.houseNumbers = true
        for index in [true, false] {
            recipe.searchIndex = index
            let settings = SettingsStore()
            let toolchain = Toolchain(settings: settings)
            let built = BuildPipeline(
                recipe: recipe,
                settings: settings,
                toolchain: toolchain,
                styles: StyleCatalog(settings: settings, toolchain: toolchain)
            )
            let options = try built.mkgmapOptions(name: "here", outputDir: scratch, tileCount: 2, gmapsupp: true)
            XCTAssertEqual(options.contains("--housenumbers"), index, "index \(index)")
        }
    }

    /// mkgmap refuses an option its help does not list, even one its code reads, and
    /// fails the whole build: every option kmap passes is one it lists.
    func testEveryOptionPassedIsOneMkgmapKnows() throws {
        var passed: [String] = []
        // With the relief layer and summits too: their options are the newest.
        var relief = pipeline.recipe
        relief.demLayer = true
        relief.fixSummits = true
        let settings = SettingsStore()
        let toolchain = Toolchain(settings: settings)
        let withRelief = BuildPipeline(
            recipe: relief,
            settings: settings,
            toolchain: toolchain,
            styles: StyleCatalog(settings: settings, toolchain: toolchain)
        )
        for built in [pipeline!, withRelief] {
            for gmapsupp in [false, true] {
                passed += try built.mkgmapOptions(name: "here", outputDir: scratch, tileCount: 2, gmapsupp: gmapsupp)
            }
        }
        passed += pipeline.gmapOptions()
        // The relief layer's own, its clipping outline written as a build writes it.
        Paths.ensure(withRelief.demPolygonFile.deletingLastPathComponent())
        try FileTools.write(Data(), to: withRelief.demPolygonFile)
        defer { FileTools.removeIfPresent(withRelief.demPolygonFile) }
        passed += withRelief.demOptions([scratch.appendingPathComponent("N43E007.hgt")], runIn: scratch)
        let java = JavaRuntime(path: "/usr/bin/java", version: "21", options: [])
        for mode in ["--gmapi", "--gmapsupp"] {
            passed += pipeline.combineArguments(
                java: java,
                mkgmap: URL(fileURLWithPath: "/tools/mkgmap.jar"),
                mode: mode,
                areaName: "here",
                outputDir: scratch,
                inputs: [],
                typ: nil
            )
        }
        let names = Set(passed.filter { $0.hasPrefix("--") }.map { String($0.dropFirst(2).prefix { $0 != "=" }) })
        XCTAssertTrue(names.isSuperset(of: ["family-id", "gmapsupp", "gmapi", "dem", "dem-poly"]), "\(names.sorted())")
        XCTAssertEqual(names.subtracting(MkgmapOptionNames.known), [])
    }

    // MARK: Finding what mkgmap wrote

    func testTheFolderIsFoundBesideTheIndexFiles() throws {
        _ = try folder("out/kmap 2026-09, here.gmap")
        try FileTools.write(Data("x".utf8), to: scratch.appendingPathComponent("out/63070000.mdx"))
        XCTAssertEqual(
            BuildPipeline.gmapFolder(in: scratch.appendingPathComponent("out"))?.lastPathComponent,
            "kmap 2026-09, here.gmap"
        )
    }

    func testTheFolderIsFoundInsideAWrapperToo() throws {
        // Another mkgmap release wraps it in a .gmapi directory.
        _ = try folder("out/here.gmapi/here.gmap")
        XCTAssertEqual(
            BuildPipeline.gmapFolder(in: scratch.appendingPathComponent("out"))?.lastPathComponent,
            "here.gmap"
        )
    }

    /// A family name naming 2 US states has 2 slashes, which mkgmap takes for folders.
    func testTheFolderIsFoundUnderTheFoldersASlashMakes() throws {
        _ = try folder("out/kmap 2026-10, us/georgia and us/alabama.gmap")
        XCTAssertEqual(
            BuildPipeline.gmapFolder(in: scratch.appendingPathComponent("out"))?.lastPathComponent,
            "alabama.gmap"
        )
    }

    func testAFileWithTheExtensionIsNotTheFolder() throws {
        let out = try folder("out")
        try FileTools.write(Data("x".utf8), to: out.appendingPathComponent("stray.gmap"))
        XCTAssertNil(BuildPipeline.gmapFolder(in: out))
        XCTAssertNil(BuildPipeline.gmapFolder(in: scratch.appendingPathComponent("absent")))
    }
}

extension GmapBundleTests {
    /// mkgmap splits --dem on commas: the cells go relative to where it runs, so a comma in
    /// the work folder's path does not cut them in 2.
    func testTheDEMCellsGoRelativeToWhereMkgmapRuns() {
        let work = URL(fileURLWithPath: "/Volumes/Data/Maps, scratch/monaco", isDirectory: true)
        let cells = work.appendingPathComponent("dem-cells", isDirectory: true)
        XCTAssertEqual(
            BuildPipeline.demOption([cells], runIn: work.appendingPathComponent("build/gmap", isDirectory: true)),
            "--dem=../../dem-cells"
        )
        XCTAssertEqual(
            BuildPipeline.demOption([cells], runIn: work.appendingPathComponent("build", isDirectory: true)),
            "--dem=../dem-cells"
        )
    }
}
