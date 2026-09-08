import Foundation

/// Folds the text files under `Assets/` back into `StyleAssets.swift`.
///
/// The rule-set payloads are compiled in rather than shipped as a resource bundle;
/// `StyleAssets.swift` is committed source, and this runs only when an asset is edited.
/// No TYP is embedded: a TYP is third-party cartography and belongs in the user's library.
enum AssetEmbedder {
    /// Where the assets live, and where their Swift lands, relative to a working copy.
    /// Written down rather than passed in: a wrong path leaves a second StyleAssets.swift
    /// beside the first, which SwiftPM refuses with "multiple producers".
    static let defaultRoot = "Assets"
    static let defaultOutput = "Sources/kmap/Build/Style/StyleAssets.swift"

    /// One embedded payload: what to call it, what to say about it, and where it lives.
    struct Asset {
        let property: String
        let doc: [String]
        let path: String
    }

    static let assets: [Asset] = [
        Asset(property: "contourLinesMetric",
              doc: ["/// Replaces mkgmap's stock `inc/contour_lines`, which labels contours in feet."],
              path: "mkgmap/contour_lines"),
        Asset(property: "iconRedirects",
              doc: ["/// Variants of one real-world kind that mkgmap's default style splits across several",
                    "/// Garmin codes, folded back onto the one code kmap styles — so one thing on the",
                    "/// ground is one icon on the screen. See Assets/mkgmap/redirects.txt."],
              path: "mkgmap/redirects.txt"),
        Asset(property: "cartoPalette",
              doc: ["/// The openstreetmap.org look as a palette table: openstreetmap-carto's colours",
                    "/// (CC0) against the type codes kmap's rules emit. The TYP is generated from it",
                    "/// at build time. See Assets/styles/osm-carto/PROVENANCE.md."],
              path: "styles/osm-carto/palette.txt"),
        Asset(property: "otmPalette",
              doc: ["/// The OpenTopoMap look as a palette table: colours read out of its own Garmin",
                    "/// TYP source (CC-BY-SA, attribution in the table's header) for every code whose",
                    "/// meaning both maps share. See Assets/styles/opentopomap/PROVENANCE.md."],
              path: "styles/opentopomap/palette.txt"),
        Asset(property: "otmPoints",
              doc: ["/// POI icon sections for the OpenTopoMap style, taken verbatim from its own",
                    "/// Garmin TYP source (© OpenTopoMap, CC-BY-SA) for every point code kmap's",
                    "/// rules also emit. See Assets/styles/opentopomap/points.txt."],
              path: "styles/opentopomap/points.txt"),
        Asset(property: "otmGraphics",
              doc: ["/// Polygon and line pattern sections for the OpenTopoMap style — forest and",
                    "/// scrub hatches, dashed borders, the rail line — taken verbatim from its TYP",
                    "/// (© OpenTopoMap, CC-BY-SA). See Assets/styles/opentopomap/graphics.txt."],
              path: "styles/opentopomap/graphics.txt"),
        Asset(property: "cyclosmPalette",
              doc: ["/// The CyclOSM look as a palette table: its ground colours (Hydda, Apache 2.0)",
                    "/// and road colours (BSD-3-Clause) against the type codes kmap's rules emit.",
                    "/// See Assets/styles/cyclosm/PROVENANCE.md and LICENSE.md."],
              path: "styles/cyclosm/palette.txt"),
        Asset(property: "cyclosmGraphics",
              doc: ["/// Dashed line sections for the CyclOSM style: its paths, tracks and",
                    "/// footways are broken hairlines, which a flat colour cannot say.",
                    "/// See Assets/styles/cyclosm/graphics.txt."],
              path: "styles/cyclosm/graphics.txt"),
        Asset(property: "libertyTopoPalette",
              doc: ["/// The OSM Liberty Topo look as a palette table: colours read from its style",
                    "/// JSON (BSD-3-Clause; look and feel CC-BY 3.0; schema © OpenMapTiles,",
                    "/// CC-BY 4.0). See Assets/styles/liberty-topo/PROVENANCE.md."],
              path: "styles/liberty-topo/palette.txt"),
        Asset(property: "libertyTopoPoints",
              doc: ["/// POI icon sections for the OSM Liberty Topo style: its own Maki markers",
                    "/// (CC0) rendered to 16 px TYP bitmaps, disc and glyph turned over at night.",
                    "/// See Assets/styles/liberty-topo/points.txt."],
              path: "styles/liberty-topo/points.txt"),
        Asset(property: "cartoPoints",
              doc: ["/// POI icon sections for the carto style: openstreetmap-carto's symbols (CC0)",
                    "/// rendered to 16 px TYP bitmaps, appended verbatim to the generated TYP.",
                    "/// See Assets/styles/osm-carto/points.txt for how they were made."],
              path: "styles/osm-carto/points.txt"),
        Asset(property: "hideableCatalogue",
              doc: ["/// Catalogue of features the user can leave off the map, generated from mkgmap's own",
                    "/// rule lines by `kmap hideable`. See Assets/hideable.txt."],
              path: "hideable.txt"),
        Asset(property: "styleWords",
              doc: ["/// The words kmap itself writes onto the map, in both label languages: labels",
                    "/// for objects OSM leaves unnamed, and the notes appended to named ones.",
                    "/// See Assets/style-words.txt."],
              path: "style-words.txt"),
        Asset(property: "hideableRussianNames",
              doc: ["/// Russian names for the hide catalogue, keyed by entry id — the English names",
                    "/// are generated from mkgmap values, so keying by them would silently fall back",
                    "/// on a rename. See Assets/hideable-ru.txt."],
              path: "hideable-ru.txt"),
        Asset(property: "defaultNameTranslations",
              doc: ["/// Russian for the labels mkgmap invents itself: its stock rules caption an",
                    "/// unnamed object with an English default_name, and OSM has no name to",
                    "/// translate — the words are mkgmap's own. See Assets/default-names-ru.txt."],
              path: "default-names-ru.txt"),
        Asset(property: "russianLabels",
              doc: ["/// Russian labels for objects OSM leaves unnamed, so an unnamed shop is not",
                    "/// captioned SUPERMARKET on a Russian map. See Assets/labels-ru.txt."],
              path: "labels-ru.txt"),
        Asset(property: "garminTypes",
              doc: ["/// The conventional Garmin type vocabulary, shown for codes the rules do not name:",
                    "/// a free slot is picked with its convention in view. See Assets/garmin-types.txt."],
              path: "garmin-types.txt"),
        Asset(property: "repairMarks",
              doc: ["/// kmap's own repair marks, added to whatever TYP a build uses.",
                    "///",
                    "/// The repair pass emits two types nothing else in the world draws, so a borrowed look",
                    "/// shows them as device defaults or not at all. See Assets/repair-marks.txt."],
              path: "repair-marks.txt"),
    ]

    /// The one payload that is not a file: kmap's own style header.
    static let styleInfo = """
    summary: kmap base rule set

    version=1

    description {
    mkgmap's default tag mapping, with contour lines relabelled in metres.
    kmap pairs this rule set with a TYP file, which is what actually decides
    how the map looks on the device.
    }
    """

    enum Trouble: Error, CustomStringConvertible, LocalizedError {
        case missing(String)
        /// A payload that could close its own literal would end the file early and take
        /// the rest of it with it.
        case wouldEscape(String)

        var description: String {
            switch self {
            case .missing(let path): return "missing asset: \(path)"
            case .wouldEscape(let path):
                return "\(path) contains the raw-string delimiter and cannot be embedded"
            }
        }
    }

    /// Five `#` on the delimiter: a payload would have to contain `"""#####` to break out.
    private static let fence = "#####"

    private static func literal(_ text: String, from path: String) throws -> String {
        guard !text.contains("\"\"\"" + fence) else { throw Trouble.wouldEscape(path) }
        return "\(fence)\"\"\"\n\(text)\n\"\"\"\(fence)"
    }

    /// The style header is written here rather than read from a file, so it has no
    /// trailing newline of its own to carry into the literal.
    private static func inlineLiteral(_ text: String) -> String {
        "\(fence)\"\"\"\n\(text)\n\"\"\"\(fence)"
    }

    static func render(from root: URL) throws -> String {
        func read(_ path: String) throws -> String {
            let url = root.appendingPathComponent(path)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw Trouble.missing(url.path)
            }
            // As it stands, trailing newline and all: the file's own last newline is
            // part of the literal, and the closing delimiter goes on the line after it.
            return text
        }

        var out = """
        import Foundation

        // Generated by `kmap embed-assets` — do not edit by hand.
        // Edit the files under Assets/ and run `make assets`.

        enum StyleAssets {


        """
        for (at, asset) in assets.enumerated() {
            for line in asset.doc { out += "    \(line)\n" }
            out += "    static let \(asset.property) =\n"
            out += try literal(read(asset.path), from: asset.path)
            out += "\n\n"
            // The style header sits between the first two.
            if at == 0 {
                out += "    static let styleInfo =\n"
                out += inlineLiteral(styleInfo)
                out += "\n\n"
            }
        }
        out += "}\n"
        return out
    }
}
