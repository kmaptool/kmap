import Foundation

/// The mkgmap invocation: every option the pipeline decides, and why.
extension BuildPipeline {
    /// The DEM spacing of the overview submap, in map units: relief for the far zooms.
    /// Smaller means more detail and a longer decode. Paired with `LevelsProfile.demBands`.
    static let overviewDEMDistance = 424192

    /// The map's identity for mkgmap. Must be identical on the tile compile and on the
    /// gmapsupp write, or the device reads two products. The code page belongs here too:
    /// without it the TYP is written with code page 0 and drops every non-ASCII label.
    func identityOptions(areaName: String) -> [String] {
        [
            "--family-id=\(recipe.familyID)",
            "--product-id=1",
            "--product-version=\(recipe.productVersion)",
            "--family-name=\(recipe.familyName)",
            "--series-name=\(recipe.seriesName)",
            "--area-name=\(areaName)",
            "--description=\(recipe.headerDescription)",
            "--code-page=\(recipe.codePage)"
        ]
    }

    /// The run that packs finished tiles rather than compiling them: `mode` is the
    /// combiner flag, the identity is the one the tiles were compiled under, and the
    /// search index is rebuilt over them all.
    func combineArguments(
        java: JavaRuntime,
        mkgmap: URL,
        mode: String,
        areaName: String,
        outputDir: URL,
        options: [String] = [],
        inputs: [URL],
        typ: URL?
    ) -> [String] {
        // Reads the cache a compile left; this short run is not worth recording.
        let warm = JavaWarmStart.plan(java: java, jar: mkgmap, heapGB: recipe.heapGB, recording: false)
        var launch: [String] = warm.options
        launch += ["-Xmx\(recipe.heapGB)g", "-jar", mkgmap.path, mode]
        launch += identityOptions(areaName: areaName)
        launch.append("--output-dir=\(outputDir.path)")
        launch += options
        var arguments = java.command(launch)
        arguments += indexOptions()
        arguments += copyrightOption()
        arguments += inputs.map(\.path)
        if let typ, FileTools.exists(typ) { arguments.append(typ.path) }
        return arguments
    }

    /// Writes the map's attribution file and returns the `--copyright-file` option. Written
    /// per build, since two of its lines describe this build. Returns an empty array if the
    /// file cannot be written, so the build continues without the credit line.
    func copyrightOption() -> [String] {
        let url = workDirectory.appendingPathComponent("copyright.txt")
        let used = recipe.contours || recipe.demLayer ? demSourcesUsed() : []
        let text = recipe.copyrightLines(demSourcesUsed: used).joined(separator: "\n") + "\n"
        guard (try? FileTools.write(text, to: url)) != nil else {
            log.warn("could not write the attribution file — the map will carry mkgmap's own")
            return []
        }
        return ["--copyright-file=\(url.path)"]
    }

    /// The numbers a person aimed a rule at in the style editor: painted or not, they
    /// are drawn.
    static func handPicked() -> [MapElementKind: Set<Int>] {
        var out: [MapElementKind: Set<Int>] = [:]
        for entry in RuleReassignments.entries() {
            guard
                let kind = MapElementKind.allCases.first(where: {
                    $0.ruleFile == entry.file
                })
            else { continue }
            for line in entry.new {
                guard let code = StyleCatalog.emittedCode(of: line, kind: kind) else {
                    continue
                }
                out[kind, default: []].insert(code)
            }
        }
        return out
    }

    /// The palette this build paints with, read as source; a compiled TYP is
    /// decompiled first, and a style with no TYP is left alone.
    private func paletteSource() -> TypSource? {
        guard let url = recipe.style.typURL else { return nil }
        if url.pathExtension.lowercased() == "txt" { return TypSource.read(url) }
        guard let binary = try? TypBinary.read(url) else { return nil }
        return TypSource.parse(TypDecompiler.source(binary))
    }

    /// The polygon types the TYP draws as a hatch on a transparent ground: a block carrying
    /// a bitmap in which any colour is `none`. Only a text TYP can be read this way; a
    /// compiled one yields nothing.
    private func hatchedPolygonTypes(in typ: URL?) -> [String] {
        guard let typ, let text = TypSource.text(of: typ) else { return [] }
        return Self.hatchedPolygonTypes(inSource: text)
    }

    /// Read by the parser that reads every TYP, so a header spelled `[_Polygon]`, or a block
    /// the next header closes rather than `[end]`, counts as mkgmap counts it.
    static func hatchedPolygonTypes(inSource text: String) -> [String] {
        TypSource.parse(text).sections
            .filter { $0.kind == .polygon && ($0.picture?.colours.contains(nil) ?? false) }
            .map { TypeMeaning.hex($0.code) }
    }

    static let packOnlyIndexOptions: Set<String> = ["--index", "--split-name-index"]

    /// The search-index options. Separate because the run that bundles finished tiles
    /// rebuilds the index and needs exactly these options and none of the others.
    func indexOptions() -> [String] {
        guard recipe.searchIndex else { return [] }
        var options = ["--index", "--poi-address"]
        if recipe.splitNameIndex {
            // Any word of a name finds it, at the cost of a much larger index.
            options.append("--split-name-index")
        }

        // Telephone boxes, benches and bus stops are the bulk of the index and are not
        // searched by name. They stay on the map and remain tappable.
        options.append("--poi-excl-index=0x2f12,0x6605,0x2f17")
        options.append("--location-autofill=is_in,nearest")
        if FileTools.exists(Paths.boundsData) {
            // Real administrative boundaries, so a street gets the right city and region.
            options.append("--bounds=\(Paths.boundsData.path)")
        }
        return options
    }

    func mkgmapOptions(
        name: String,
        outputDir: URL,
        tileCount: Int,
        gmapsupp: Bool = true,
        typ: URL? = nil,
        shapeLift: String? = nil
    ) throws -> [String] {
        var options: [String] = []
        /// The rule files this build compiles from, once the snapshot is decided: the
        /// drawing order is read from the same rules mkgmap is given.
        var styleUsed: URL?

        if let styleDir = recipe.style.styleDirectory, FileTools.exists(styleDir) {
            // mkgmap reads the style while it runs and the materialized style is shared,
            // so each build compiles from a snapshot of its own.
            let mine = workDirectory.appendingPathComponent("style", isDirectory: true)
            // Taken and checked when the style was prepared; taken here only where not.
            if FileTools.exists(mine) || (try? styles.snapshot(styleDir, to: mine)) != nil {
                // A repair mark that had to move off a number the borrowed style draws
                // takes its rules with it, here in the snapshot.
                let moved = try StyleCatalog.moveRepairRules(repairMoves, in: mine)
                if moved > 0 { log.append("\(moved) repair rule(s) moved with their mark") }
                if let source = paletteSource() {
                    // The fallback first, then the silencing: what neither the new
                    // number nor the old one can paint goes quiet.
                    _ = try StyleCatalog.keepTheOldNumberWherePaletteIsSilent(
                        in: mine,
                        palette: source,
                        log: log
                    )
                    // Only a palette written for kmap's numbers. Every other kind leaves
                    // what it does not paint to the receiver on purpose, and always has.
                    if source.lines.contains(where: {
                        $0.trimmingCharacters(in: .whitespaces)
                            .hasSuffix(StylePort.forOurNumbers)
                    }) {
                        _ = try StyleCatalog.keepOnlyWhatThePaletteDraws(
                            in: mine,
                            palette: source,
                            chosen: BuildPipeline.handPicked(),
                            log: log
                        )
                    }
                }
                options.append("--style-file=\(mine.path)")
                styleUsed = mine
            } else {
                options.append("--style-file=\(styleDir.path)")
                styleUsed = styleDir
            }
        }

        options += identityOptions(areaName: name)
        options += [
            "--overview-mapname=\(recipe.overviewMapID)",
            // The mapname names the file; the id inside is a separate option whose default
            // is a constant, which would collide between two maps on one card.
            "--overview-mapnumber=\(recipe.overviewMapID)",
            "--overview-dem-dist=\(Self.overviewDEMDistance)",
            // Lets mkgmap join line fragments cut at subdivision borders even when it must
            // reverse one, where oneway and type allow. Fewer headers, faster paint.
            "--allow-reverse-merge",
            "--levels=\(recipe.levels.levels)",
            "--overview-levels=\(recipe.levels.overviewLevels)",
            "--output-dir=\(outputDir.path)",
            // mkgmap finishes when its slowest tile does, and jobs sharing one heap hold
            // each other back when there are more than the heap can feed. See compileJobs.
            "--max-jobs=\(Machine.compileJobs(tiles: tileCount, heapGB: recipe.heapGB, nodesPerTile: recipe.maxNodesPerTile))"
        ]
        if gmapsupp { options.append("--gmapsupp") }
        options += copyrightOption()

        if !recipe.effectiveNameTagList.isEmpty {
            options.append("--name-tag-list=\(recipe.effectiveNameTagList)")
        }
        if recipe.routable { options.append("--route") }
        // The search index itself is built where the tiles are packed, over them all: a
        // compile alone would build one only to throw it away. The address options stay,
        // as the tiles carry what they find.
        options += indexOptions().filter { gmapsupp || !Self.packOnlyIndexOptions.contains($0) }
        // Address search only: mkgmap indexes house numbers off the building outlines, and
        // receivers show no address lines on the map-cursor card.
        if recipe.writesHouseNumbers { options.append("--housenumbers") }

        if recipe.generateSea {
            if FileTools.exists(Paths.seaData) {
                // Precompiled coastline polygons: the only reliable source for a regional
                // extract, whose coastline ways are cut at the boundary and never close.
                options.append("--precomp-sea=\(Paths.seaData.path)")
                options.append("--generate-sea=multipolygon,land-tag=natural=land")
            } else {
                // Derived from the extract's own coastline. `floodblocker` drops a sea
                // polygon containing streets, which would otherwise flood inland areas.
                options.append(
                    "--generate-sea=multipolygon,extend-sea-sectors,close-gaps=6000,"
                        + "floodblocker,land-tag=natural=land"
                )
            }
        }

        // The x- options below exist only in a patched mkgmap (see Toolchain.patchMkgmap)
        // and are guarded, since an unknown x- option is ignored silently.
        if toolchain.mkgmapIsPatched {
            // The same width the splitter widens delivery by; the two must not drift apart.
            // A narrower band leaves the seam visible, a wider one paints over a neighbour.
            options.append("--x-shape-clip-overlap=\(recipe.shapeOverlap)")
            // Hatched fills are handed over whole: a receiver anchors a pattern to the
            // polygon's bounding box, so clipped copies differ in phase and read doubled.
            let whole = hatchedPolygonTypes(in: typ)
            if !whole.isEmpty {
                options.append("--x-shape-clip-whole=" + whole.joined(separator: ","))
            }
            // A glade drawn across a wood larger than itself takes a number the TYP this
            // build compiles draws over the woods.
            if let shapeLift { options.append(shapeLift) }
            // Land is opaque and tile-sized, so it gets a narrower band: enough to cover a
            // receiver clipping a tile to its frame, never past the delivery overlap.
            let landBand = min(recipe.landOverlap, recipe.shapeOverlap)
            options.append("--x-shape-clip-exact=\(StyleCatalog.landPolygonType):\(landBand)")
            // Contours travel with the shapes; every other line stops at the frame because
            // routing is joined there. Otherwise the band carries landcover but no contours.
            options.append(
                "--x-line-clip-overlap="
                    + StyleCatalog.contourLineTypes.joined(separator: ",")
            )
            // What covers what is decided by the order the lines are stored in, and left
            // to itself that is the order they arrived in: a river could cover the road it
            // passes under. The style's own road rules give every road type a rank.
            if let styleDir = styleUsed, let index = RuleSetIndex.read(styleDirectory: styleDir),
                let order = LineDrawOrder.option(
                    in: index,
                    overContours: recipe.contours ? StyleCatalog.contourLineCodes : []
                )
            {
                options.append(order)
            }
        }

        // --min-size-polygon is measured in the level's own units, so one threshold drops far
        // more ground at coarse levels. Nothing is dropped for size below level 18.
        options.append("--polygon-size-limits=24:8, 18:0")
        options.append("--add-pois-to-areas")

        if recipe.demLayer {
            let paths = stageDEMCells()
            if paths.isEmpty {
                log.warn("DEM layer requested but no .hgt files were found — skipping it")
            } else {
                options += demOptions(paths, runIn: outputDir)
            }
        }

        return options
    }

    func demOptions(_ cells: [URL], runIn outputDir: URL) -> [String] {
        var options = [
            Self.demOption(cells, runIn: outputDir),
            // One distance per zoom level, from the source's own spacing upward.
            "--dem-dists=" + recipe.levels.demDists(oneArcSecond: hasOneArcSecondData),
            // mkgmap's own default interpolation.
            "--dem-interpolation=auto"
        ]
        if FileTools.exists(demPolygonFile) { options.append("--dem-poly=\(demPolygonFile.nativePath)") }
        return options
    }
}
