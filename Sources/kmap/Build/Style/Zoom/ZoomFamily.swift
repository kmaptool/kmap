import Foundation

/// A group of features that appear together on the zoom ladder, and the tags identifying it.
///
/// The seven rungs of the ladder are fixed; which family sits on each is configurable. The
/// points file yields two families, so place labels move independently of POI icons.
struct ZoomFamily: Identifiable, Equatable {
    let id: String
    /// The English name, and the key `t()` translates by.
    let nameKey: String
    /// What the family covers, for the panel beside the list.
    let noteKey: String
    /// Which of the style's rule files to look in.
    let files: [String]
    /// `key=value`, or `key=*` for the whole key. A rule matches if its condition names
    /// any of these.
    let tags: [String]
    /// Whether every typed rule in `files` belongs to this family, tags unread. Set where a
    /// file holds one kind of rule and the rules carry no condition to match against.
    var wholeFile: Bool = false

    /// Match order, which is also the editor's listing order. A rule naming two families
    /// goes to the first that claims it, so narrower families precede broader ones.
    static let all: [ZoomFamily] = [
        ZoomFamily(id: "contours", nameKey: "Contour lines",
                   noteKey: "the elevation lines and their labels",
                   files: ["inc/contour_lines"], tags: [], wholeFile: true),
        // Before roads, which are `highway=*`: a track is a trail first.
        ZoomFamily(id: "trails", nameKey: "Trails and tracks",
                   noteKey: "paths, tracks, footways, steps, via ferrata — what you walk",
                   files: ["lines"],
                   tags: ["highway=path", "highway=track", "highway=footway",
                          "highway=bridleway", "highway=cycleway", "highway=steps",
                          "highway=via_ferrata", "highway=byway", "highway=unsurfaced"]),
        ZoomFamily(id: "roads", nameKey: "Roads",
                   noteKey: "everything a vehicle drives on, link roads and slip roads too",
                   files: ["lines", "polygons"], tags: ["highway=*"]),
        ZoomFamily(id: "railways", nameKey: "Rail and cableways",
                   noteKey: "rail, tram, funicular and the aerialways",
                   files: ["lines", "polygons"], tags: ["railway=*", "aerialway=*"]),
        ZoomFamily(id: "water", nameKey: "Water",
                   noteKey: "rivers, lakes, wetland, the coast and the sea",
                   files: ["lines", "polygons"],
                   tags: ["waterway=*", "dock=*", "natural=water", "natural=wetland",
                          "natural=marsh", "natural=mud", "natural=bay", "natural=beach",
                          "natural=sand", "natural=coastline", "natural=sea",
                          "natural=spring", "natural=waterfall"]),
        ZoomFamily(id: "woodland", nameKey: "Woodland",
                   noteKey: "forest, wood and scrub — the fills that cover the most ground",
                   files: ["polygons"],
                   tags: ["landuse=forest", "landuse=wood", "natural=wood", "natural=scrub"]),
        ZoomFamily(id: "terrain", nameKey: "Open ground",
                   noteKey: "cliffs, scree, bare rock, grassland, glacier, valleys, cutlines",
                   files: ["lines", "polygons"],
                   tags: ["natural=cliff", "natural=scree", "natural=shingle",
                          "natural=bare_rock", "natural=rock", "natural=stone",
                          "natural=grassland", "natural=heath", "natural=tundra",
                          "natural=glacier", "natural=valley", "natural=land",
                          "natural=fell", "man_made=cutline", "kmap:fell_edge=*"]),
        ZoomFamily(id: "protected", nameKey: "Protected land",
                   noteKey: "reserves, national parks and their outlines",
                   files: ["lines", "polygons"],
                   tags: ["boundary=protected_area", "boundary=national_park",
                          "leisure=nature_reserve"]),
        ZoomFamily(id: "military", nameKey: "Military land",
                   noteKey: "ranges, danger areas, barracks and airfields — worth seeing early",
                   files: ["lines", "polygons"],
                   tags: ["military=*", "landuse=military", "kmap:mil_edge=*"]),
        ZoomFamily(id: "places", nameKey: "Settlements",
                   noteKey: "villages, suburbs, squares and named islands, as ground",
                   files: ["polygons"], tags: ["place=*"]),
        ZoomFamily(id: "buildings", nameKey: "Buildings",
                   noteKey: "building outlines, which are many and small",
                   files: ["polygons", "lines"], tags: ["building=*"]),
        ZoomFamily(id: "barriers", nameKey: "Barriers",
                   noteKey: "fences, walls, gates and hedges — what stops you",
                   files: ["lines"], tags: ["barrier=*"]),
        ZoomFamily(id: "power", nameKey: "Power lines",
                   noteKey: "transmission lines and their pylons: landmarks in open country",
                   files: ["lines", "polygons"], tags: ["power=*"]),
        ZoomFamily(id: "aviation", nameKey: "Aviation",
                   noteKey: "runways, taxiways, aprons and airfield ground",
                   files: ["lines", "polygons"], tags: ["aeroway=*"]),
        ZoomFamily(id: "boundaries", nameKey: "Boundaries",
                   noteKey: "administrative borders, which the device also draws itself",
                   files: ["lines", "polygons"], tags: ["boundary=*"]),
        ZoomFamily(id: "parking", nameKey: "Parking",
                   noteKey: "car parks and their ground, as an area rather than a POI",
                   files: ["lines", "polygons"],
                   tags: ["amenity=parking", "amenity=parking_space", "parking=*"]),
        ZoomFamily(id: "sport", nameKey: "Sport and leisure",
                   noteKey: "pitches, tracks, playgrounds, parks and gardens",
                   files: ["lines", "polygons"], tags: ["leisure=*", "sport=*"]),
        // The points file. Place names first, so the whole-file family below cannot claim
        // them.
        ZoomFamily(id: "placenames", nameKey: "Place names",
                   noteKey: "the labels of cities, towns and villages",
                   files: ["points"], tags: ["place=*"]),
        ZoomFamily(id: "pois", nameKey: "POIs",
                   noteKey: "every point icon — shops, springs, peaks, bus stops",
                   files: ["points"], tags: [], wholeFile: true),
        // Last and deliberately broad: whatever the narrower families left.
        ZoomFamily(id: "landuse", nameKey: "Land use",
                   noteKey: "farmland, industry, housing, shops, tourism — whatever is left",
                   files: ["lines", "polygons"],
                   tags: ["landuse=*", "amenity=*", "man_made=*", "shop=*", "tourism=*",
                          "historic=*", "route=*", "junction=*", "natural=*"]),
    ]

    static func named(_ id: String) -> ZoomFamily? { all.first { $0.id == id } }

    var name: String { t(nameKey) }
    var note: String { t(noteKey) }

    /// Whether a rule in `file` belongs to this family. `file` is a parameter because a
    /// whole-file family claims every condition it is shown. `condition` must be everything
    /// before the `[` opening the type, and matching is on whole tokens.
    func claims(_ condition: String, in file: String) -> Bool {
        guard files.contains(file) else { return false }
        if wholeFile { return true }
        return tags.contains { tag in
            if tag.hasSuffix("=*") {
                return ZoomFamily.names(key: String(tag.dropLast(2)), in: condition)
            }
            return ZoomFamily.names(exact: tag, in: condition)
        }
    }

    private static func names(key: String, in condition: String) -> Bool {
        found(key + "=", in: condition, checkAfter: false)
    }

    private static func names(exact tag: String, in condition: String) -> Bool {
        found(tag, in: condition, checkAfter: true)
    }

    /// True where `needle` occurs as a whole token. `checkAfter` is false for a `key=`
    /// search, where a value is expected to follow.
    private static func found(_ needle: String, in condition: String,
                              checkAfter: Bool) -> Bool {
        var from = condition.startIndex
        while let hit = condition.range(of: needle, range: from..<condition.endIndex) {
            let before: Character? = hit.lowerBound == condition.startIndex
                ? nil : condition[condition.index(before: hit.lowerBound)]
            let after: Character? = hit.upperBound == condition.endIndex
                ? nil : condition[hit.upperBound]
            if !isWordCharacter(before), !checkAfter || !isWordCharacter(after) { return true }
            from = hit.upperBound
        }
        return false
    }

    private static func isWordCharacter(_ c: Character?) -> Bool {
        guard let c else { return false }
        return c.isLetter || c.isNumber || c == "_" || c == ":" || c == "="
    }
}
