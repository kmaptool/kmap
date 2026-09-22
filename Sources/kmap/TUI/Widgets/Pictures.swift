import Foundation

/// A TYP picture shown as itself: swatches, icons drawn in cell colours, and one row of
/// colours for a list entry.
extension Widgets {
    /// Cells across per pixel: a cell is about twice as tall as it is wide, so two side by
    /// side are square.
    static let cellsPerPixel = 2
    /// The width of a swatch unless the screen says otherwise.
    static let swatchWidth = 2

    /// A block of one colour, `width` cells wide, returning the column after it. A nil or
    /// unparsable colour is drawn as a rule, standing for transparency.
    @discardableResult
    static func swatch(
        _ s: Surface,
        x: Int,
        y: Int,
        colour: String?,
        width: Int = swatchWidth,
        theme: Theme
    ) -> Int {
        guard width > 0 else { return x }
        if let colour, let parsed = Color.hex(colour) {
            s.fill(Rect(x: x, y: y, w: width, h: 1), Style(fg: parsed, bg: parsed))
        } else {
            s.hline(x, y, width, Glyph.barEmpty, Style(fg: theme.faint, bg: theme.appBg))
        }
        return x + width
    }

    /// The size a picture is drawn at, in cells.
    struct PictureFit {
        /// Whole-number reduction. 1 draws every pixel; 2 draws one cell per 2x2 block.
        let scale: Int
        let columns: Int
        let rows: Int
        var isReduced: Bool { scale > 1 }
    }

    /// The size a picture will be drawn at, reduced by whole steps until it fits.
    static func pictureFit(
        _ block: XpmBlock,
        maxColumns: Int = .max,
        maxRows: Int = .max
    ) -> PictureFit {
        let width = block.width, height = block.height
        guard width > 0, height > 0, maxColumns >= cellsPerPixel, maxRows >= 1 else {
            return PictureFit(scale: 1, columns: 0, rows: 0)
        }
        var scale = 1
        while true {
            let columns = ((width + scale - 1) / scale) * cellsPerPixel
            let rows = (height + scale - 1) / scale
            if (columns <= maxColumns && rows <= maxRows) || scale >= max(width, height) {
                return PictureFit(scale: scale, columns: columns, rows: rows)
            }
            scale += 1
        }
    }

    /// Draws a TYP picture as background-coloured cells, one row per pixel row, reduced by
    /// a whole factor where it does not fit. Transparent pixels are drawn as `background`.
    ///
    /// - Returns: the number of rows used.
    @discardableResult
    static func picture(
        _ s: Surface,
        x: Int,
        y: Int,
        _ block: XpmBlock,
        background: Color,
        maxColumns: Int = .max,
        maxRows: Int = .max
    ) -> Int {
        guard let grid = block.pixels() else { return 0 }
        let fit = pictureFit(block, maxColumns: maxColumns, maxRows: maxRows)
        guard fit.rows > 0, fit.columns > 0 else { return 0 }
        let clear = Style(fg: background, bg: background)

        for row in 0..<fit.rows {
            for column in 0..<(fit.columns / cellsPerPixel) {
                let colour = average(grid, x: column * fit.scale, y: row * fit.scale, over: fit.scale, on: background)
                let style = colour.map { Style(fg: $0, bg: $0) } ?? clear
                for cell in 0..<cellsPerPixel {
                    s.put(x + column * cellsPerPixel + cell, y + row, " ", style)
                }
            }
        }
        return fit.rows
    }

    /// A picture reduced to a single row of cell colours, nil where nothing is painted.
    /// Returned rather than drawn, for callers that have one row per entry.
    static func colourRow(_ block: XpmBlock, width: Int, on background: Color) -> [Color?] {
        guard width > 0, let grid = block.pixels() else { return [] }
        let fit = pictureFit(block, maxColumns: width, maxRows: 1)
        guard fit.columns > 0 else { return [] }
        var out: [Color?] = []
        for column in 0..<(fit.columns / cellsPerPixel) {
            let colour = average(grid, x: column * fit.scale, y: 0, over: fit.scale, on: background)
            for _ in 0..<cellsPerPixel { out.append(colour) }
        }
        return out
    }

    /// Paints one row of colours into the lower half of its cells, leaving a gap above so
    /// adjacent list entries stay separated without spending a row.
    static func halfRow(_ s: Surface, x: Int, y: Int, colours: [Color?], background: Color) {
        for (i, colour) in colours.enumerated() {
            guard let colour else { continue }
            s.put(x + i, y, Glyph.lowerHalf, Style(fg: colour, bg: background))
        }
    }

    /// One cell of a reduced picture: the mean of the pixels it covers, mixed with
    /// `background` in proportion to the transparent pixels among them. Nil when every
    /// covered pixel is transparent.
    private static func average(
        _ grid: [[String?]],
        x: Int,
        y: Int,
        over scale: Int,
        on background: Color
    ) -> Color? {
        var r = 0, g = 0, b = 0, opaque = 0, seen = 0
        for py in y..<(y + scale) {
            guard let line = grid[safe: py] else { continue }
            for px in x..<(x + scale) where px < line.count {
                seen += 1
                guard let text = line[px], let colour = Color.hex(text),
                    case .rgb(let cr, let cg, let cb) = colour.kind
                else { continue }
                r += Int(cr); g += Int(cg); b += Int(cb)
                opaque += 1
            }
        }
        guard opaque > 0, seen > 0 else { return nil }
        let ink = (r / opaque, g / opaque, b / opaque)
        guard opaque < seen, case .rgb(let br, let bg, let bb) = background.kind else {
            return .rgb(UInt8(ink.0), UInt8(ink.1), UInt8(ink.2))
        }
        func mix(_ over: Int, _ under: Int) -> UInt8 {
            UInt8((over * opaque + under * (seen - opaque)) / seen)
        }
        return .rgb(mix(ink.0, Int(br)), mix(ink.1, Int(bg)), mix(ink.2, Int(bb)))
    }
}
