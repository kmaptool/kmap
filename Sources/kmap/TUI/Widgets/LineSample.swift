import Foundation

/// A line style shown as itself: casing, fill and casing at the widths the style gives.
extension Widgets {
    /// Draws a plain line as casing, fill and casing, scaled down to `rect.h` when the
    /// widths do not fit.
    ///
    /// - Returns: the number of rows used.
    @discardableResult
    static func lineSample(
        _ s: Surface,
        rect: Rect,
        fill: String?,
        casing: String?,
        width: Int?,
        border: Int?,
        background: Color
    ) -> Int {
        guard rect.w > 0, rect.h > 0 else { return 0 }
        let fillColour = fill.flatMap(Color.hex)
        let casingColour = casing.flatMap(Color.hex)
        // An unspecified width is one pixel, as on the receiver.
        let wanted = max(1, width ?? 1)
        let borderRows = casingColour == nil ? 0 : max(1, border ?? 1)

        let thickness: Int
        let casingRows: Int
        if wanted + borderRows * 2 <= rect.h {
            thickness = wanted
            casingRows = borderRows
        } else {
            // Too tall to draw to scale: one casing row each side of whatever is left.
            casingRows = borderRows > 0 && rect.h >= 3 ? 1 : 0
            thickness = max(1, rect.h - casingRows * 2)
        }
        let rows = thickness + casingRows * 2
        let top = rect.y + max(0, (rect.h - rows) / 2)

        for i in 0..<rows {
            let colour = (i < casingRows || i >= casingRows + thickness) ? casingColour : fillColour
            let style = colour.map { Style(fg: $0, bg: $0) } ?? Style(fg: background, bg: background)
            s.fill(Rect(x: rect.x, y: top + i, w: rect.w, h: 1), style)
        }
        return rows
    }
}
