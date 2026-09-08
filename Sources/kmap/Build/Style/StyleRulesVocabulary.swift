import Foundation

/// Meanings kmap drew as one and a borrowed style draws apart.
///
/// Two meanings on one number share a look: allotments and an orchard both sat on 0x4e.
/// Each gets a number of kmap's own, and a palette that paints no picture for the new
/// number keeps the old one (below), so no map changes until a palette says otherwise.
extension StyleCatalog {

    /// A meaning moved onto a number of its own, and the number it drew on before: an
    /// unpainted new number sends the rule back to the old one, so a style written
    /// before the widening draws exactly what it drew. `was: nil` is a layer that never
    /// existed — a building's outline — and is removed instead.
    static let widenedNumbers: [(kind: MapElementKind, now: Int, was: Int?)] = [
        (.polygon, 0x5a, 0x4e),   // allotments, drawn as an orchard before
        (.polygon, 0x0d, 0x0c),   // a quarry, drawn as industrial ground before
        (.polygon, 0x1b, 0x4e),   // a vineyard, drawn as an orchard before
        (.polygon, 0x1e, 0x4f),   // heath, drawn as scrub before
        (.polygon, 0x1f, nil),    // a mountain plateau: new, and only where drawn
        (.polygon, 0x28, nil),    // a salt pond: new
        (.polygon, 0x29, nil),    // greenhouses: new
        (.line, 0x0e, 0x16),      // a path, drawn as a footway before
        (.line, 0x0f, 0x16),      // steps, retagged into a footway before
        (.line, 0x10, 0x06),      // a living street, drawn as a minor road before
        (.line, 0x31, 0x17),      // a row of trees, drawn as a fence before
        (.line, 0x32, nil),       // a city wall: new, and only where drawn
        (.line, 0x33, 0x1f),      // a canal, drawn as a river before
        (.line, 0x34, 0x18),      // a drain, drawn as a stream before
        (.line, 0x35, 0x18),      // a ditch, drawn as a stream before
        (.line, 0x2f, nil),       // a building's outline: new, and only where drawn
        (.point, 0x0d00, 0x0b00), // a hamlet, drawn as a locality before
        (.point, 0x6608, 0x6411), // a tower, drawn as a mast before
    ]

    /// Puts a widened rule back on the number it drew on before. Runs before the
    /// palette filter, which would otherwise silence it and lose the meaning.
    @discardableResult
    static func keepTheOldNumberWherePaletteIsSilent(in directory: URL, palette: TypSource,
                                                     log: Log) throws -> Int {
        var moved = 0
        for kind in MapElementKind.allCases {
            let wanted = widenedNumbers.filter { $0.kind == kind }
            guard !wanted.isEmpty else { continue }
            let painted = palette.codes(kind).union(palette.deliberatelyUnstyled[kind] ?? [])
            guard !painted.isEmpty else { continue }
            let url = directory.appendingPathComponent(kind.ruleFile)
            guard var text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var touched = false
            for entry in wanted where !painted.contains(entry.now) {
                let from = "[" + TypeMeaning.hex(entry.now) + " "
                guard text.contains(from) else { continue }
                // A number a person aimed a rule at by hand keeps it.
                func mine(_ line: String) -> Bool {
                    line.contains(from) && !line.contains(RuleReassignment.mark)
                }
                guard let was = entry.was else {
                    // A `continue` layer, so the rule below still lays the fill down.
                    // Left in, it would reach the receiver's own drawing.
                    text = text.components(separatedBy: "\n")
                        .filter { !mine($0) }.joined(separator: "\n")
                    touched = true
                    moved += 1
                    continue
                }
                let to = "[" + TypeMeaning.hex(was) + " "
                text = text.components(separatedBy: "\n")
                    .map { mine($0) ? $0.replacingOccurrences(of: from, with: to) : $0 }
                    .joined(separator: "\n")
                touched = true
                moved += 1
            }
            if touched { try text.write(to: url, atomically: true, encoding: .utf8) }
        }
        if moved > 0 {
            log.append("\(moved) rule(s) drawn on the number they had before"
                       + " — this palette paints no picture for the newer one")
        }
        return moved
    }

    func widenDrawnVocabulary(in directory: URL, log: Log) throws {
        var done: [String] = []

        // Steps are retagged into a footway before any drawing rule sees them. Drawn on
        // their own number first, and routable: a staircase is still a way through.
        if try edit(file: "lines", in: directory,
                    old: """
                    highway=steps | highway=corridor | highway=stepping_stones | highway=elevator | highway=escalator | highway=platform
                        {set highway=footway; add bicycle=no}
                    """,
                    new: """
                    # kmap: steps keep a number of their own — a style that draws a
                    # staircase apart from a footpath has somewhere to put it.
                    highway=steps [0x0f road_class=0 road_speed=0 resolution 24]
                    highway=corridor | highway=stepping_stones | highway=elevator | highway=escalator | highway=platform
                        {set highway=footway; add bicycle=no}
                    """) {
            done.append("steps")
        }

        // Allotments and an orchard are both 0x4e in the stock rules; the dacha plots
        // around a Russian town are neither an orchard nor invisible.
        if try edit(file: "polygons", in: directory,
                    old: "landuse=allotments [0x4e resolution 21]",
                    new: "landuse=allotments [0x5a resolution 21]  # kmap: not the orchard's number") {
            done.append("allotments")
        }

        // A row of trees shared the number of dams, weirs and fences.
        if try edit(file: "lines", in: directory,
                    old: "natural=tree_row [0x17 resolution 24]",
                    new: "natural=tree_row [0x31 resolution 24]  # kmap: not the fence's number") {
            done.append("tree row")
        }

        // Ground kmap drew as its neighbour: a quarry is not an industrial estate, a
        // vineyard not an orchard, heath not scrub.
        for (name, old, new) in [
            ("quarry", "landuse=quarry [0x0c resolution 19]",
             "landuse=quarry [0x0d resolution 19]  # kmap: not the industrial estate's number"),
            ("vineyard", "landuse=vineyard [0x4e resolution 20]",
             "landuse=vineyard [0x1b resolution 20]  # kmap: not the orchard's number"),
            ("heath", "natural=heath [0x4f resolution 21]",
             "natural=heath [0x1e resolution 21]  # kmap: not the scrub's number"),
        ] where try edit(file: "polygons", in: directory, old: old, new: new) {
            done.append(name)
        }

        // Ways kmap drew as their neighbour. The two that carry traffic keep a plain
        // number a receiver will route on.
        for (name, old, new) in [
            // Still on mkgmap's own rung here: `showTrailsEarlier` moves it to 22 later,
            // and knows the number this gives it.
            ("path", "highway=path [0x16 road_class=0 road_speed=0 resolution 23]",
             "highway=path [0x0e road_class=0 road_speed=0 resolution 23]"
             + "  # kmap: not the footway's number"),
            ("living street", "highway=living_street [0x06 road_class=0 road_speed=1 resolution 22]",
             "highway=living_street [0x10 road_class=0 road_speed=1 resolution 22]"
             + "  # kmap: not the minor road's number"),
            ("canal", "waterway=canal [0x1f resolution 21]",
             "waterway=canal [0x33 resolution 21]  # kmap: not the river's number"),
            ("drain", "waterway=stream | waterway=drain [0x18 resolution 22]",
             "waterway=stream [0x18 resolution 22]\n"
             + "waterway=drain [0x34 resolution 22]  # kmap: not the stream's number"),
            ("ditch", "waterway=ditch [0x18 resolution 23]",
             "waterway=ditch [0x35 resolution 23]  # kmap: not the stream's number"),
        ] where try edit(file: "lines", in: directory, old: old, new: new) {
            done.append(name)
        }

        // A tower stands where a mast and a chimney also stood.
        if try edit(file: "points", in: directory,
                    old: "man_made=tower | man_made=mast | landmark=chimney"
                         + " [0x6411 resolution 24]",
                    new: "man_made=tower [0x6608 resolution 24]"
                         + "  # kmap: not the mast's number\n"
                         + "man_made=mast | landmark=chimney [0x6411 resolution 24]") {
            done.append("tower")
        }

        // A hamlet is not a locality: one is a place people live in, the other a name on
        // empty ground, and a borrowed style draws them apart.
        if try edit(file: "points", in: directory,
                    old: "place=hamlet                     & name=* [0x0b00 resolution 24]",
                    new: "place=hamlet                     & name=* [0x0d00 resolution 24]"
                         + "  # kmap: not the locality's number") {
            done.append("hamlet")
        }

        // Ground kmap drew as nothing at all, each on the rung its kindred sit on.
        let ground = "# --- kmap: ground a borrowed style may draw"
        if try spliceRules("""


        \(ground) ------------------------------------
        # None of kmap's own palettes paints these yet, and a number no palette paints
        # draws nothing at all — so a style that has a picture for a plateau or a salt
        # pond shows one, and every other style is exactly as it was.

        natural=fell [0x1f resolution 19]
        landuse=salt_pond [0x28 resolution 20]
        landuse=greenhouse_horticulture | landuse=greenhouse [0x29 resolution 21]

        """, marked: ground, intoFile: "polygons", in: directory) {
            done.append("plateau, salt pond, greenhouses")
        }

        let wall = "# --- kmap: city wall"
        if try spliceRules("""


        \(wall) ---------------------------------------------------
        # A city wall is a landmark, not a fence: kmap drew it as neither.

        barrier=city_wall [0x32 resolution 22]

        """, marked: wall, intoFile: "lines", in: directory) {
            done.append("city wall")
        }

        // A building's outline as a line of its own: styles that draw one do it over the
        // fill, so the rule continues and the polygon rules still lay the fill down.
        let outline = "# --- kmap: building outlines"
        if try spliceRules("""


        \(outline) --------------------------------------------
        # A borrowed style may draw the outline of a building as a line over the fill.
        # `continue` so the way still reaches the polygon rules and keeps its fill.

        building=* & building!=no [0x2f resolution 24 continue]

        """, marked: outline, intoFile: "lines", in: directory) {
            done.append("building outlines")
        }

        if !done.isEmpty {
            log.append("drawn vocabulary widened: \(done.joined(separator: ", "))")
        }
    }

    /// One exact-text edit of a rule file. Returns false where the text has changed in
    /// this mkgmap and the anchor no longer matches — the caller says nothing then, and
    /// the stock rule stands.
    private func edit(file: String, in directory: URL, old: String, new: String) throws
        -> Bool {
        let url = directory.appendingPathComponent(file)
        guard var text = try? String(contentsOf: url, encoding: .utf8),
              text.contains(old) else { return false }
        text = text.replacingOccurrences(of: old, with: new)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return true
    }
}
