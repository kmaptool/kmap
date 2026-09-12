import Foundation

/// Every choice a build is started with.
struct BuildRecipe {
    /// The region the map is named and numbered after.
    var region: Region
    /// Further regions built into the same map. All share one family id and one set of
    /// tiles, so routing crosses between them; separate maps cannot route across.
    var extraRegions: [Region] = []
    /// Every region going in, primary first.
    var regions: [Region] { [region] + extraRegions }
    var style: MapStyle

    /// Vector contour lines generated from elevation data.
    var contours: Bool = true
    var contourInterval: Int = 10

    /// The raster elevation grid embedded in the map, giving shaded relief and the
    /// elevation profile. Independent of the contour lines.
    var demLayer: Bool = true
    /// Lift the DEM at each summit to the height OSM gives it, where the relief agrees:
    /// the cell under a summit reads below it. See `BurnPeaks`.
    var fixSummits: Bool = true
    /// Copernicus needs no login and covers the globe; the sources chain, so GLO-90
    /// fills the few cells GLO-30 does not publish.
    static let recommendedDEMSources = "copernicus1,copernicus3"
    var demSources: String = BuildRecipe.recommendedDEMSources

    var routable: Bool = true
    var searchIndex: Bool = true
    var houseNumbers: Bool = true
    var generateSea: Bool = true

    /// mkgmap's `--code-page`. Decides which alphabet survives into the map, and overrides
    /// the CodePage declared inside the TYP. 1252 is Latin-1, 1251 Cyrillic.
    var codePage: Int = CodePage.westernEuropean

    var levels: LevelsProfile = .smooth

    /// Which OSM name tag to label with. Empty leaves mkgmap's own behaviour: plain `name`.
    var nameTagList: String = ""

    /// Where OSM `description` is carried so the device can show it. Every carrier but
    /// `inName` uses an address field, which requires the object to be a POI with an
    /// address block and is shown only when the object is opened, never on the map.
    enum DescriptionCarrier: String, CaseIterable {
        /// Descriptions are not carried.
        case off
        /// Rides in the address line; the text can reach the address index.
        case street
        /// Stays out of mkgmap's index, which covers POI names and not phone numbers. The
        /// receiver labels the line as a phone number, and some firmware hides it.
        case phone
        /// Rides in the region line. Renders reliably; region-based address search stops
        /// working.
        case region
        /// Rides in the postcode line.
        case postcode
        /// Appended to the object's name in brackets. Works on anything that carries a
        /// name, and is the only carrier also drawn on the map.
        case inName

        var label: String {
            switch self {
            case .off: return t("off")
            case .street: return t("as address line")
            case .phone: return t("as phone line (kept out of search)")
            case .region: return t("as region line (what OpenTopoMap uses)")
            case .postcode: return t("as postcode line")
            case .inName: return t("after the name in brackets — also drawn on the map")
            }
        }

        /// The address tag the text rides in; nil for carriers that use none.
        var tag: String? {
            switch self {
            case .off, .inName: return nil
            case .street: return "mkgmap:street"
            case .phone: return "mkgmap:phone"
            case .region: return "mkgmap:region"
            case .postcode: return "mkgmap:postal_code"
            }
        }
    }

    var descriptions: DescriptionCarrier = .off

    /// The `--name-tag-list` this build passes. An explicit list passes through untouched;
    /// otherwise a 1251 build falls back to a Cyrillic-first order, since mkgmap replaces
    /// every character the code page cannot hold with `?`. A 1252 build passes nothing.
    var effectiveNameTagList: String {
        if !nameTagList.isEmpty { return nameTagList }
        return codePage == 1251 ? "name:ru,name,int_name,name:en" : ""
    }

    /// Which zoom plan populates the rungs of the `levels` ladder. A rung is an index into
    /// that ladder.
    var zoomPlan: ZoomPlan = .asMeasured

    /// Also write a Garmin Custom POI file next to the map, holding every object with an
    /// OSM description. `.gpi` is the only Garmin format with a description field.
    var customPOIs: Bool = false

    /// Index each word of a street name separately, so any word finds the street. This
    /// multiplies the number of index entries and slows search on some receivers.
    var splitNameIndex: Bool = true

    /// Close gaps where OSM left a road end short of the junction it was drawn for. Only
    /// where closing the gap changes what a route can do, never on distance alone and
    /// never across a barrier. Off by default: it alters the source data.
    var healRoadEnds: Bool = false

    /// How far to look for the line a dangling end was meant to join, in metres.
    var healRadius: Double = BuildRecipe.defaultHealRadius
    /// Metres. Named because the help screen quotes it where no build is in hand.
    static let defaultHealRadius: Double = 5.0

    /// Feature ids from `HideableFeature.all` to leave off the map. Suppressed at build
    /// time, so a rebuild without the id brings the feature back.
    var hidden: Set<String> = []

    /// True when a chosen feature is split by the kind of way it stands on. That tag does
    /// not exist in OSM, so the extract has to be annotated before splitting.
    var needsBarrierContext: Bool {
        hidden.contains { $0.hasPrefix("barriers-") }
    }

    /// The Garmin product identity of this map. Two maps sharing a family id read as one
    /// product and only one is shown. A borrowed TYP's family id is not inherited: mkgmap
    /// rewrites the embedded TYP to whatever `--family-id` says.
    var familyID: Int = 6324

    /// Tile ids are `familyID x 10000 + n`, the convention Garmin's own products follow.
    /// Distinct per map, so two maps never claim the same tiles.
    var mapIDBase: Int { familyID * 10000 + 1 }

    /// The overview map's id: the slot before the first tile. Numeric and family-scoped,
    /// because mkgmap names the overview file after this and a non-numeric name falls back
    /// to a shared constant; the gmapsupp combiner also drops input files named `ovm_*`.
    var overviewMapID: Int { familyID * 10000 }

    /// How the finished map is cut into files.
    var splitMode: SplitMode = .fitCard
    /// Which country each region belongs to, for `.perCountry`. Filled where the region
    /// tree is at hand, since a region knows only its parent.
    var countryOf: [String: String] = [:]
    /// Where finished maps are collected. Each build gets its own dated sub-folder.
    var outputDirectory: URL
    /// Scratch space, wiped after the build unless `keepWorkFiles` is set.
    var workRoot: URL = Paths.work
    /// Stamped once when the recipe is created so the folder name cannot drift mid-build.
    var startedOn: Date = Date()
    var maxNodesPerTile: Int = 3_500_000

    /// Which of the TYP's two drawings this build packs. See `TypEdit.Theme`.
    var theme: TypEdit.Theme = .all

    /// How far past its own frame a tile may paint a shape, in map units, and the same for
    /// the land layer alone. Both need the seam patch; stock mkgmap cannot draw past a
    /// frame. See `TileSplitter.shapeClipOverlap` and `landClipOverlap`.
    var shapeOverlap: Int = Int(TileSplitter.shapeClipOverlap)
    var landOverlap: Int = Int(TileSplitter.landClipOverlap)

    var heapGB: Int = 8
    var downloadConnections: Int = 4

    /// The ground the whole map covers: every region's bounds together. Elevation, contours
    /// and the split axis read this rather than the primary region's own box.
    var coverage: BBox {
        var box = region.bbox
        for extra in extraRegions where extra.bbox.isValid {
            box.extend(lon: extra.bbox.minLon, lat: extra.bbox.minLat)
            box.extend(lon: extra.bbox.maxLon, lat: extra.bbox.maxLat)
        }
        return box
    }

    /// Needs elevation data on disk, for either purpose.
    var needsElevationData: Bool { contours || demLayer }
}
