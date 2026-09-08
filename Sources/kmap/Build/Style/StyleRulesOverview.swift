import Foundation

/// Rules about what survives zooming out, and what is never drawn at all.
///
/// The overview map is one image for the whole area, so everything that reaches it is
/// paid for at every zoom.
extension StyleCatalog {
    /// The wooded fills whose texture is a drawing rather than a tint, held back to the
    /// resolution the paths appear at. Matched as whole rule strings, not by type code,
    /// which is why they come from the same builder that wrote them — in either language.
    private static func woodedIconRules(cyrillic: Bool) -> [String] {
        forestTypeRuleLines(cyrillic: cyrillic, resolution: 19) + [
            "landuse=forest | landuse=wood [0x50 resolution 19]",
            "natural=wood [0x50 resolution 19]",
            "natural=scrub [0x4f resolution 19]"
        ]
    }

    /// Moves ground cover — woodland, grassland, scrub, rivers — one resolution finer, off
    /// the ten-to-thirty-kilometre zoom, and lowers the far-zoom roads onto the overview
    /// submap. Water bodies, protected areas, roads, contours and POI steps are untouched.
    func thinTheOverview(in directory: URL, cyrillic: Bool, log: Log) throws {
        var moved = 0
        var roads = 0
        for name in ["polygons", "lines"] {
            let url = directory.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var out = StyleCatalog.overviewDiet(in: text, cyrillic: cyrillic)
            let far = StyleCatalog.farRoads(in: out.text)
            out.text = far.text
            roads += far.moved
            guard out.moved > 0 || far.moved > 0 else { continue }
            try out.text.write(to: url, atomically: true, encoding: .utf8)
            moved += out.moved
        }
        if moved > 0 {
            log.append("\(moved) ground-cover rule(s) moved off the ten-kilometre zoom")
        }
        if roads > 0 {
            log.append("\(roads) road rule(s) lowered onto the overview submap")
        }
    }

    /// Lifts closed military ground to the resolution the conservation areas are drawn at.
    /// Military facilities keep their own resolution: a building is not a zone.
    static func restrictedMilitary(in text: String) -> (text: String, moved: Int) {
        var out = text
        var moved = 0
        let restricted = [
            "landuse=military [0x04 resolution 19]",
            "military=danger_area [0x11 resolution 20]",
            "military=range [0x04 resolution 20]"
        ]
        for rule in restricted where out.contains(rule) {
            let lifted = rule
                .replacingOccurrences(of: "resolution 19]", with: "resolution 18]")
                .replacingOccurrences(of: "resolution 20]", with: "resolution 18]")
            out = out.replacingOccurrences(of: rule, with: lifted)
            moved += 1
        }
        return (out, moved)
    }

    static func overviewDiet(in text: String, cyrillic: Bool) -> (text: String, moved: Int) {
        var out = text
        var moved = 0
        let lighter = forestTypeRuleLines(cyrillic: cyrillic, resolution: 18) + [
            "landuse=forest | landuse=wood [0x50 resolution 18]",
            "natural=scrub [0x4f resolution 18]",
            "natural=wood [0x50 resolution 18]",
            "natural=scree | natural=shingle [0x54 resolution 18]",
            "natural=bare_rock | natural=rock & area=yes | natural=stone [0x56 resolution 18]",
            "natural=grassland [0x55 resolution 18]",
            "waterway=river [0x1f resolution 18]"
        ]
        for rule in lighter where out.contains(rule) {
            out = out.replacingOccurrences(
                of: rule, with: rule.replacingOccurrences(of: "resolution 18]",
                                                          with: "resolution 19]"))
            moved += 1
        }

        // The wooded types carry a drawn texture rather than a wash, so the symbols wait
        // for resolution 22, where the paths arrive. The floor 0x59 stays at 18.
        for rule in Self.woodedIconRules(cyrillic: cyrillic) where out.contains(rule) {
            out = out.replacingOccurrences(
                of: rule, with: rule.replacingOccurrences(of: "resolution 19]",
                                                          with: "resolution 22]"))
            moved += 1
        }
        return (out, moved)
    }

    /// Lowers the roads a person navigates the far zooms by onto the overview submap,
    /// which carries resolutions 15, 14 and 13 only. The stock rules put the trunk at 18
    /// and the primary at 19, below anything the submap can hold.
    static func farRoads(in text: String) -> (text: String, moved: Int) {
        var out = text
        var moved = 0
        let lowered = [
            ("highway=motorway & mkgmap:fast_road=yes [0x01 road_class=4 road_speed=7 resolution 14]",
             "highway=motorway & mkgmap:fast_road=yes [0x01 road_class=4 road_speed=7 resolution 13]"),
            ("highway=motorway [0x01 road_class=4 road_speed=7 resolution 15]",
             "highway=motorway [0x01 road_class=4 road_speed=7 resolution 14]"),
            ("highway=trunk & mkgmap:fast_road=yes [0x02 road_class=4 road_speed=5 resolution 15]",
             "highway=trunk & mkgmap:fast_road=yes [0x02 road_class=4 road_speed=5 resolution 14]"),
            ("highway=trunk [0x02 road_class=4 road_speed=5 resolution 18]",
             "highway=trunk [0x02 road_class=4 road_speed=5 resolution 15]"),
            ("highway=primary & mkgmap:fast_road=yes [0x03 road_class=4 road_speed=4 resolution 17]",
             "highway=primary & mkgmap:fast_road=yes [0x03 road_class=4 road_speed=4 resolution 15]"),
            ("highway=primary [0x03 road_class=3 road_speed=4 resolution 19]",
             "highway=primary [0x03 road_class=3 road_speed=4 resolution 16]"),
            // The state border is the one line a person orients the far view by; at 17 it
            // never reached the submap.
            ("boundary=national [0x1e resolution 17]",
             "boundary=national [0x1e resolution 14]")
        ]
        for (old, new) in lowered where out.contains(old) {
            out = out.replacingOccurrences(of: old, with: new)
            moved += 1
        }
        return (out, moved)
    }

    /// Drops the chosen features from the rule set.
    ///
    /// Each substitution keeps the rule's actions and removes only its `[0x… ]` type, so
    /// routing still happens. Nothing is removed from the source data.
    func hideFeatures(_ hidden: Set<String>, in directory: URL, log: Log) throws {
        guard !hidden.isEmpty else { return }
        var applied: [String] = []
        var missed: [String] = []

        for id in hidden.sorted() {
            guard let feature = HideableFeature.feature(id: id) else { continue }
            var ok = false
            for substitution in feature.substitutions {
                let url = directory.appendingPathComponent(substitution.file)
                guard var text = try? String(contentsOf: url, encoding: .utf8),
                      text.contains(substitution.old) else { continue }
                text = text.replacingOccurrences(of: substitution.old, with: substitution.new)
                try text.write(to: url, atomically: true, encoding: .utf8)
                ok = true
            }
            if ok { applied.append(feature.name) } else { missed.append(feature.name) }
        }

        if !applied.isEmpty { log.append("hidden: \(applied.joined(separator: ", "))") }
        for name in missed {
            log.warn("could not hide \(name) — the rule has changed in this mkgmap")
        }
    }
}
