import Foundation

/// The looks kmap carries in the binary: each a palette table the TYP is written from on
/// every build, so edits to the written file do not survive.
extension StyleCatalog {

    struct ShippedPalette {
        let id: String
        let name: String
        let summary: String
        let fid: Int
        let palette: String
        let points: String
        /// Ready `[_polygon]`/`[_line]` sections that replace the palette's flat colours.
        /// Empty for a look that is flat colour throughout.
        var graphics: String = ""
        /// The line the style's licence asks to see, written into every map built with
        /// it. Empty where the source asks for nothing.
        var credit: String = ""
    }

    static let shippedPalettes: [ShippedPalette] = [
        ShippedPalette(
            id: "osm-carto",
            name: "OpenStreetMap",
            summary: "the openstreetmap.org look — openstreetmap-carto's colours on kmap's"
                   + " rule set",
            fid: 6325,
            palette: StyleAssets.cartoPalette,
            points: StyleAssets.cartoPoints),
        ShippedPalette(
            id: "opentopomap",
            name: "OpenTopoMap",
            summary: "the OpenTopoMap look — its own Garmin colours where the maps share"
                   + " a meaning (© OpenTopoMap, CC-BY-SA)",
            fid: 6326,
            palette: StyleAssets.otmPalette,
            points: StyleAssets.otmPoints,
            graphics: StyleAssets.otmGraphics,
            credit: "Style: OpenTopoMap, CC-BY-SA"),
        ShippedPalette(
            id: "cyclosm",
            name: "CyclOSM",
            summary: "the CyclOSM look — an outdoor palette, warmer and quieter than"
                   + " carto's (© CyclOSM, BSD-3-Clause; colours from Hydda, Apache 2.0)",
            fid: 6327,
            palette: StyleAssets.cyclosmPalette,
            points: StyleAssets.cartoPoints,
            graphics: StyleAssets.cyclosmGraphics,
            credit: "Style: CyclOSM, BSD-3-Clause; colours from Hydda, Apache 2.0"),
        ShippedPalette(
            id: "liberty-topo",
            name: "OSM Liberty Topo",
            summary: "a minimal topographic look — quiet ground, orange roads, contour"
                   + " browns (© OSM Liberty Topo, BSD; © OpenMapTiles, CC-BY 4.0)",
            fid: 6328,
            palette: StyleAssets.libertyTopoPalette,
            points: StyleAssets.libertyTopoPoints,
            credit: "Style: OSM Liberty Topo, BSD/CC-BY 3.0; (c) OpenMapTiles, CC-BY 4.0"),
    ]

    static func shippedPalette(id: String) -> ShippedPalette? {
        shippedPalettes.first { $0.id == id }
    }

    static func shippedTypURL(of shipped: ShippedPalette) -> URL {
        Paths.styles.appendingPathComponent("\(shipped.id).typ.txt")
    }

    /// The TYP source a shipped palette stands for, icons included.
    static func shippedTypText(of shipped: ShippedPalette) throws -> String {
        TypGenerator.text(from: try StylePalette.read(shipped.palette),
                          fid: shipped.fid, points: shipped.points,
                          graphics: shipped.graphics)
    }
}
