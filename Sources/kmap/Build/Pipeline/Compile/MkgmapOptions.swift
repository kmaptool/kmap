import Foundation

/// The mkgmap invocation: every option the pipeline decides, and why.
extension BuildPipeline {
    /// The map's identity for mkgmap. Must be identical on the tile compile and on the
    /// gmapsupp write, or the device reads two products. The code page belongs here too:
    /// without it the TYP is written with code page 0 and drops every non-ASCII label.
    func identityOptions(areaName: String) -> [String] {
        ["--family-id=\(recipe.familyID)",
         "--product-id=1",
         "--family-name=\(recipe.familyName)",
         "--series-name=\(recipe.seriesName)",
         "--area-name=\(areaName)",
         "--description=\(recipe.headerDescription)",
         "--code-page=\(recipe.codePage)"]
    }


    /// Writes the map's attribution file and returns the `--copyright-file` option. Written
    /// per build, since two of its lines describe this build. Returns an empty array if the
    /// file cannot be written, so the build continues without the credit line.
    func copyrightOption() -> [String] {
        let url = workDirectory.appendingPathComponent("copyright.txt")
        let text = recipe.copyrightLines.joined(separator: "\n") + "\n"
        guard (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil else {
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
            guard let kind = MapElementKind.allCases.first(where: {
                $0.ruleFile == entry.file
            }) else { continue }
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
        guard let typ, let text = try? String(contentsOf: typ, encoding: .utf8) else { return [] }
        var out: [String] = []
        for block in text.components(separatedBy: "[_polygon]").dropFirst() {
            let body = block.components(separatedBy: "[end]").first ?? ""
            guard body.contains("Xpm=\""), !body.contains("Xpm=\"0 0"),
                  body.contains(" c none") else { continue }
            guard let line = body.split(separator: "\n")
                    .first(where: { $0.hasPrefix("Type=") }) else { continue }
            let code = line.dropFirst("Type=".count).trimmingCharacters(in: .whitespaces)
            if !code.isEmpty { out.append(code) }
        }
        return out
    }


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


    func mkgmapOptions(name: String, outputDir: URL, tileCount: Int,
                               gmapsupp: Bool = true, typ: URL? = nil) -> [String] {
        var options: [String] = []
        /// The rule files this build compiles from, once the snapshot is decided: the
        /// drawing order is read from the same rules mkgmap is given.
        var styleUsed: URL?

        if let styleDir = recipe.style.styleDirectory, FileTools.exists(styleDir) {
            // mkgmap reads the style while it runs and the materialized style is shared,
            // so each build compiles from a snapshot of its own.
            let mine = workDirectory.appendingPathComponent("style", isDirectory: true)
            if (try? styles.snapshot(styleDir, to: mine)) != nil {
                // A repair mark that had to move off a number the borrowed style draws
                // takes its rules with it, here in the snapshot.
                let moved = StyleCatalog.moveRepairRules(repairMoves, in: mine)
                if moved > 0 { log.append("\(moved) repair rule(s) moved with their mark") }
                if let source = paletteSource() {
                    // The fallback first, then the silencing: what neither the new
                    // number nor the old one can paint goes quiet.
                    _ = try? StyleCatalog.keepTheOldNumberWherePaletteIsSilent(
                        in: mine, palette: source, log: log)
                    // Only a palette written for kmap's numbers. Every other kind leaves
                    // what it does not paint to the receiver on purpose, and always has.
                    if source.lines.contains(where: {
                        $0.trimmingCharacters(in: .whitespaces)
                            .hasSuffix(StylePort.forOurNumbers)
                    }) {
                        _ = try? StyleCatalog.keepOnlyWhatThePaletteDraws(
                            in: mine, palette: source, chosen: BuildPipeline.handPicked(),
                            log: log)
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
            // A DEM on the overview submap makes a receiver shade the far zooms; a smaller
            // value means more relief detail and a longer decode. Paired with `demBands`.
            "--overview-dem-dist=424192",
            // Lets mkgmap join line fragments cut at subdivision borders even when it must
            // reverse one, where oneway and type allow. Fewer headers, faster paint.
            "--allow-reverse-merge",
            // Without this the TYP is written with code page 0 and every non-ASCII label
            // inside it is dropped silently.
            "--code-page=\(recipe.codePage)",
            "--levels=\(recipe.levels.levels)",
            "--overview-levels=\(recipe.levels.overviewLevels)",
            "--output-dir=\(outputDir.path)",
            // mkgmap finishes when its slowest tile does, and jobs sharing one heap hold
            // each other back when there are more than the heap can feed. See compileJobs.
            "--max-jobs=\(Machine.compileJobs(tiles: tileCount, heapGB: recipe.heapGB, nodesPerTile: recipe.maxNodesPerTile))",
        ]
        if gmapsupp { options.append("--gmapsupp") }
        options += copyrightOption()

        if !recipe.effectiveNameTagList.isEmpty {
            options.append("--name-tag-list=\(recipe.effectiveNameTagList)")
        }
        if recipe.routable { options.append("--route") }
        options += indexOptions()
        // Address search only: mkgmap indexes house numbers off the building outlines, and
        // receivers show no address lines on the map-cursor card.
        if recipe.houseNumbers { options.append("--housenumbers") }

        if recipe.generateSea {
            if FileTools.exists(Paths.seaData) {
                // Precompiled coastline polygons: the only reliable source for a regional
                // extract, whose coastline ways are cut at the boundary and never close.
                options.append("--precomp-sea=\(Paths.seaData.path)")
                options.append("--generate-sea=multipolygon,land-tag=natural=land")
            } else {
                // Derived from the extract's own coastline. `floodblocker` drops a sea
                // polygon containing streets, which would otherwise flood inland areas.
                options.append("--generate-sea=multipolygon,extend-sea-sectors,close-gaps=6000,"
                               + "floodblocker,land-tag=natural=land")
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
            // Land is opaque and tile-sized, so it gets a narrower band: enough to cover a
            // receiver clipping a tile to its frame, never past the delivery overlap.
            let landBand = min(recipe.landOverlap, recipe.shapeOverlap)
            options.append("--x-shape-clip-exact=\(StyleCatalog.landPolygonType):\(landBand)")
            // Contours travel with the shapes; every other line stops at the frame because
            // routing is joined there. Otherwise the band carries landcover but no contours.
            options.append("--x-line-clip-overlap="
                           + StyleCatalog.contourLineTypes.joined(separator: ","))
            // What covers what is decided by the order the lines are stored in, and left
            // to itself that is the order they arrived in: a river could cover the road it
            // passes under. The style's own road rules give every road type a rank.
            if let styleDir = styleUsed, let index = RuleSetIndex.read(styleDirectory: styleDir),
               let order = LineDrawOrder.option(in: index) {
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
                options.append("--dem=" + paths.map(\.path).joined(separator: ","))
                // One distance per zoom level, from the source's own spacing upward.
                options.append("--dem-dists=" + recipe.levels.demDists(oneArcSecond: hasOneArcSecondData))
                // mkgmap's own default interpolation.
                options.append("--dem-interpolation=auto")
            }
        }

        return options
    }
}
