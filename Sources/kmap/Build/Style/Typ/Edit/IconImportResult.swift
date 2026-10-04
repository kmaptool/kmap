import Foundation

extension IconImport {
    enum ImportError: LocalizedError {
        case notFound(String)
        case unreadable(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .notFound(let path): return t("%@: no such file", path)
            case .unreadable(let name):
                return t(
                    "%@ could not be read as a picture. PNG, JPEG, TIFF, GIF and BMP "
                        + "work; SVG works where the system can draw it.",
                    name
                )
            case .empty: return t("that picture has no pixels in it")
            }
        }
    }

    /// The drawing, and everything that had to be decided to get it.
    struct Result {
        let block: XpmBlock

        /// The size the file was drawn at, before anything was done to it.
        let sourceWidth: Int
        let sourceHeight: Int

        /// Distinct opaque colours in the source, before the palette was capped.
        let sourceColours: Int
        /// How many the drawing ended up with, transparency counted.
        let paletteSize: Int

        /// Pixels that were neither solid nor clear and had to be forced one way. A picture
        /// drawn on the pixel grid has none; one rasterised from a curve has a rim of them.
        let softEdgePixels: Int

        /// True when the file was already the size asked for, so nothing was resampled.
        var wasExactSize: Bool { sourceWidth == block.width && sourceHeight == block.height }

        /// Notes worth showing before the drawing is used, most important first.
        var warnings: [String] {
            var out: [String] = []
            if !wasExactSize {
                out.append(
                    "scaled from \(sourceWidth)×\(sourceHeight) — a drawing made for "
                        + "one size rarely survives another"
                )
            }
            if softEdgePixels > 0 {
                out.append(
                    "\(softEdgePixels) pixel(s) were part-transparent and had to be "
                        + "made solid or clear; a TYP has no alpha"
                )
            }
            if sourceColours > paletteSize {
                out.append("\(sourceColours) colours reduced to \(paletteSize)")
            }
            return out
        }
    }
}
