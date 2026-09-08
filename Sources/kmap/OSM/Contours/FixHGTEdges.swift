import Foundation

/// Repairs the dead outer row or column a warped .hgt tile is left with.
///
/// A `.hgt` holds nodes on the tile's edge while a cell grid such as Copernicus GLO-30
/// covers the same square, so resampling writes nodata, stored as zero, along the rim.
/// The repair copies the adjacent row or column over the dead one, and only where a whole
/// edge is zero while its neighbour is not, leaving a real coastline alone.
enum FixHGTEdges {
    /// Grid sides this repairs: one and three arc-seconds. Any other size is left alone.
    static let sides = [3601, 1201]

    /// Repairs one tile in place, returning the edges filled, or nil where none was.
    @discardableResult
    static func repair(_ url: URL) throws -> String? {
        var data = [UInt8](try Data(contentsOf: url))
        guard let side = sides.first(where: { $0 * $0 * 2 == data.count }) else { return nil }

        func sample(_ row: Int, _ column: Int) -> Int16 {
            let at = (row * side + column) * 2
            return Int16(bitPattern: UInt16(data[at]) << 8 | UInt16(data[at + 1]))
        }
        func copy(from source: (row: Int, column: Int), to target: (row: Int, column: Int)) {
            let a = (source.row * side + source.column) * 2
            let b = (target.row * side + target.column) * 2
            data[b] = data[a]
            data[b + 1] = data[a + 1]
        }
        func columnIsDead(_ c: Int) -> Bool {
            for r in 0..<side where sample(r, c) != 0 { return false }
            return true
        }
        func rowIsDead(_ r: Int) -> Bool {
            for c in 0..<side where sample(r, c) != 0 { return false }
            return true
        }

        var filled: [String] = []
        if columnIsDead(side - 1) && !columnIsDead(side - 2) {
            for r in 0..<side { copy(from: (r, side - 2), to: (r, side - 1)) }
            filled.append("east")
        }
        // Some sources zero this one instead.
        if columnIsDead(0) && !columnIsDead(1) {
            for r in 0..<side { copy(from: (r, 1), to: (r, 0)) }
            filled.append("west")
        }
        if rowIsDead(side - 1) && !rowIsDead(side - 2) {
            for c in 0..<side { copy(from: (side - 2, c), to: (side - 1, c)) }
            filled.append("south")
        }
        if rowIsDead(0) && !rowIsDead(1) {
            for c in 0..<side { copy(from: (1, c), to: (0, c)) }
            filled.append("north")
        }

        guard !filled.isEmpty else { return nil }
        try Data(data).write(to: url)
        return filled.joined(separator: ",")
    }
}
