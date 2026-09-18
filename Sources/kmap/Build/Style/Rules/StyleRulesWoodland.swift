import Foundation

/// Rules about land and what grows on it: the land polygon under everything, woodland by
/// kind and the ground cover beside it. Each reads and rewrites the style's `polygons`
/// file in place.
extension StyleCatalog {
    /// A land polygon under everything, so a receiver never shows its own map background.
    /// `--generate-sea` with `land-tag=natural=land` produces one per tile; without a rule
    /// here the tiles drop it. Emitted as 0x27: mkgmap refuses 0x4a in a style rule.
    func addLandUnderEverything(in directory: URL, log: Log) throws {
        let marker = "# --- kmap: land under everything"
        let rules = """


        \(marker) --------------------------------------------
        # The generate-sea land polygons. Resolution 17 puts them on every tile level,
        # so the ground is always a real polygon and never the device's own background.
        #
        # The TYP has to hold up its end, in a way a GPSMAP 67 never shows and a fenix
        # does: the background 0x4b must sit on a draw level of its OWN, below this type.
        # Sharing a level is not an order -- mkgmap writes a subdivision's shapes by
        # descending area, so two tile-sized polygons take turns and the watch goes black
        # at every zoom. Colouring the land red does not help: it is drawn, and lost.
        natural=land [\(StyleCatalog.landPolygonType) resolution 17]

        """
        guard try spliceRules(rules, marked: marker, intoFile: "polygons", in: directory)
        else { return }
        log.append("land drawn under everything, so the device background never shows")
    }

    func lowerWoodlandResolution(in directory: URL, log: Log) throws {
        let polygons = directory.appendingPathComponent("polygons")
        guard var text = try? String(contentsOf: polygons, encoding: .utf8) else { return }
        let edits = [
            ("landuse=forest | landuse=wood [0x50 resolution 20]",
             "landuse=forest | landuse=wood [0x50 resolution 18]"),
            ("natural=wood [0x50 resolution 20]", "natural=wood [0x50 resolution 18]"),
            ("natural=scrub [0x4f resolution 20]", "natural=scrub [0x4f resolution 18]")
        ]
        var done = 0
        for (old, new) in edits where text.contains(old) {
            text = text.replacingOccurrences(of: old, with: new)
            done += 1
        }
        guard done > 0 else {
            log.warn("woodland rules have changed in this mkgmap — left at their own zoom")
            return
        }
        try text.write(to: polygons, atomically: true, encoding: .utf8)
        log.append("woodland drawn from resolution 18, as the rest of the landcover is")
    }

    /// The three forest kinds, and the words a build labels them with.
    static func forestKinds(cyrillic: Bool)
        -> [(tag: String, type: String, suffix: String, alone: String)] {
        let words = StyleWords(cyrillic: cyrillic)
        return [("needleleaved", "0x57",
                 words("forest.coniferous-suffix"), words("forest.coniferous")),
                ("broadleaved", "0x58",
                 words("forest.broadleaved-suffix"), words("forest.broadleaved")),
                ("mixed", "0x50",
                 words("forest.mixed-suffix"), words("forest.mixed"))]
    }

    /// The six leaf-type rules exactly as `addForestTypeRules` writes them, at
    /// `resolution`. The overview diet matches these lines verbatim to move them, so
    /// both sides come from this one builder - in either language.
    static func forestTypeRuleLines(cyrillic: Bool, resolution: Int) -> [String] {
        let wood = "(landuse=forest | landuse=wood | natural=wood)"
        var out: [String] = []
        for k in forestKinds(cyrillic: cyrillic) {
            out.append("\(wood) & leaf_type=\(k.tag) & name=* "
                     + "{ name '${name} (\(k.suffix))' } [\(k.type) resolution \(resolution)]")
            out.append("\(wood) & leaf_type=\(k.tag) "
                     + "{ name '\(k.alone)' } [\(k.type) resolution \(resolution)]")
        }
        return out
    }

    /// Tells coniferous woodland from broadleaved, by OSM's `leaf_type`, in the fill and in
    /// the label. Mixed keeps 0x50, the both-symbols texture shared with forest of unknown
    /// kind. Most stands are unnamed, so an unnamed one takes the kind as its whole label.
    func addForestTypeRules(in directory: URL, cyrillic: Bool, log: Log) throws {
        let marker = "# --- kmap: forest by leaf type"
        let wood = "(landuse=forest | landuse=wood | natural=wood)"
        var rules = [marker + " ------------------------------------",
                     "# Every wood first lays a plain floor, 0x59, and carries on to its own",
                     "# type below. mkgmap merges neighbouring shapes of one type and never",
                     "# merges across types, so a broadleaved stand against a needleleaved one",
                     "# leaves two shapes that only touch -- and a GPSMAP 67 rounds the shared",
                     "# edge to a white hairline of map background. Traced to the exact",
                     "# 0x50/0x58 boundary in the built tile. The floor is flat colour, the one",
                     "# the three forest tiles already sit on, so the hairline shows forest.",
                     "\(wood) [0x59 resolution 18 continue]",
                     "# See addForestTypeRules. Before the stock rules, which type any wood",
                     "# alike, so a stand with leaf_type never reaches them.",
                     ""]
        rules.append(contentsOf: Self.forestTypeRuleLines(cyrillic: cyrillic, resolution: 18))
        rules.append("")
        rules.append("")

        switch try insertRules(rules.joined(separator: "\n"), marked: marker,
                               beforeLineWith: "landuse=forest | landuse=wood [0x50",
                               intoFile: "polygons", in: directory) {
        case .added:
            log.append("forest split by leaf type — "
                       + "\(Self.forestKinds(cyrillic: cyrillic).count) kinds")
        case .missingAnchor:
            log.warn("the stock forest rule was not found — leaf types left undrawn")
        case .leftAlone:
            break
        }
    }

    /// Ground cover the stock rule set leaves blank: `natural=grassland`, `natural=bare_rock`
    /// and `natural=scree` appear in no mkgmap rule. Each gets a type of its own;
    /// bare rock does not reuse 0x52, which is tundra.
    func addGroundCoverRules(in directory: URL, log: Log) throws {
        let marker = "# --- kmap: ground cover"
        let rules = """


        \(marker) ------------------------------------------------
        # Landcover mkgmap's own rules do not mention at all.
        # Resolution 18 matches the neighbouring cover types (forest, scrub, sand), so the
        # treeline and the rock line appear together rather than at different zooms.

        # natural=fell is deliberately absent: a high plateau gets no flat fill of its own.
        # Its green rim in `lines` draws the shape and carries the name, and the
        # protected-area hatch above it is what should read inside — a tint under the
        # hatch only muddies it, and vendor styles do not fill the plateaux either.
        # Grassland alone: a meadow is already mkgmap's own 0x1c a few rules up, and
        # the clause this once carried for it (`landuse=meadow & natural=grassland`)
        # was a subset of the first and never drew a thing.
        natural=grassland [0x55 resolution 18]
        # A closed way tagged natural=stone is a boulder traced round rather than
        # dropped as a node -- 20 of them here, against 230 nodes. Same ground, so
        # the same fill; the nodes are handled in `points` below.
        natural=bare_rock | natural=rock & area=yes | natural=stone [0x56 resolution 18]
        natural=scree | natural=shingle [0x54 resolution 18]

        """
        guard try spliceRules(rules, marked: marker, intoFile: "polygons", in: directory)
        else { return }

        // The lone boulders go in `points` and nowhere else: 0x6614 is a POI type, and
        // mkgmap refuses the whole style if a polygon rule offers it.
        let pointRules = """


            \(marker) ------------------------------------------------
            # 230 lone boulders carry natural=stone, which no rule mentions; they are
            # landmarks on open ground and share the icon the 615 natural=rock points
            # already use, one line below in the stock file.

            natural=stone [0x6614 resolution 24]

            """
        try spliceRules(pointRules, marked: marker, intoFile: "points", in: directory)

        log.append("grassland, bare rock and scree given ground cover")
    }
}
