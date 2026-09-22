import Foundation

/// A rectangle of cells, by its top-left corner and size.
struct Rect {
    var x: Int
    var y: Int
    var w: Int
    var h: Int

    var maxX: Int { x + w }
    var maxY: Int { y + h }

    func inset(by n: Int) -> Rect {
        Rect(x: x + n, y: y + n, w: max(0, w - 2 * n), h: max(0, h - 2 * n))
    }

    func inset(dx: Int, dy: Int) -> Rect {
        Rect(x: x + dx, y: y + dy, w: max(0, w - 2 * dx), h: max(0, h - 2 * dy))
    }

    /// Splits off `n` columns from the left, returning (left, remainder).
    func splitLeft(_ n: Int) -> (Rect, Rect) {
        let cut = max(0, min(n, w))
        return (
            Rect(x: x, y: y, w: cut, h: h),
            Rect(x: x + cut, y: y, w: w - cut, h: h)
        )
    }

    /// Splits off `n` rows from the top, returning (top, remainder).
    func splitTop(_ n: Int) -> (Rect, Rect) {
        let cut = max(0, min(n, h))
        return (
            Rect(x: x, y: y, w: w, h: cut),
            Rect(x: x, y: y + cut, w: w, h: h - cut)
        )
    }
}
