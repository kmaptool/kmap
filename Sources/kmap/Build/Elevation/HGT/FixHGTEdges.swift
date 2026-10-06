import Foundation

/// Repairs the dead outer row or column a warped .hgt tile is left with.
///
/// A `.hgt` holds nodes on the tile's edge while a cell grid such as Copernicus GLO-30
/// covers the same square, so resampling writes nodata, stored as zero, along the rim.
/// A whole edge of zeros beside a live line is filled, a real coastline left alone: from
/// the next tile's own edge where it is in the same directory, so the seam agrees, else
/// from the adjacent line.
enum FixHGTEdges {
    /// Grid sides this repairs: 1 and 3 arc-seconds. Any other size is left alone.
    static let sides = [3601, 1201]

    /// Repairs one tile in place, returning the edges filled, or nil where none was.
    /// `cell` and `directory` name the tile's place, to look for its neighbours there.
    @discardableResult
    static func repair(_ url: URL, cell: (lat: Int, lon: Int)? = nil, in directory: URL? = nil) throws -> String? {
        var data = [UInt8](try Data(contentsOf: url))
        guard let side = sides.first(where: { $0 * $0 * 2 == data.count }) else { return nil }

        /// The tile beside this one, whole and of this size, or nil; mapped: only its edge is read.
        func neighbour(_ dLat: Int, _ dLon: Int) -> Data? {
            guard let cell, let directory else { return nil }
            var lon = cell.lon + dLon
            if lon > 179 { lon -= 360 }
            if lon < -180 { lon += 360 }
            let file = directory.appendingPathComponent(HGTName.of(lat: cell.lat + dLat, lon: lon) + ".hgt")
            guard FileTools.size(of: file) == Int64(side * side * 2),
                let bytes = try? Data(contentsOf: file, options: .alwaysMapped)
            else { return nil }
            return bytes
        }
        /// Copies an edge of `other` into this tile, both walked by sample index; false
        /// when there is no such tile or its edge is dead too.
        func take(_ other: Data?, from source: (Int) -> Int, to target: (Int) -> Int) -> Bool {
            guard let other else { return false }
            let base = other.startIndex
            var live = false
            for i in 0..<side where other[base + source(i) * 2] != 0 || other[base + source(i) * 2 + 1] != 0 {
                live = true
                break
            }
            guard live else { return false }
            for i in 0..<side {
                data[target(i) * 2] = other[base + source(i) * 2]
                data[target(i) * 2 + 1] = other[base + source(i) * 2 + 1]
            }
            return true
        }

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
        // Each edge is the neighbour's opposite edge: east is the east tile's column 0.
        let last = side - 1
        // Judged before any is filled: a corner taken from a neighbour would make the
        // edge across it look alive.
        let deadEast = columnIsDead(last) && !columnIsDead(last - 1)
        let deadWest = columnIsDead(0) && !columnIsDead(1)
        let deadSouth = rowIsDead(last) && !rowIsDead(last - 1)
        let deadNorth = rowIsDead(0) && !rowIsDead(1)
        if deadEast {
            if !take(neighbour(0, 1), from: { $0 * side }, to: { $0 * side + last }) {
                for r in 0..<side { copy(from: (r, last - 1), to: (r, last)) }
            }
            filled.append("east")
        }
        // Some sources zero this one instead.
        if deadWest {
            if !take(neighbour(0, -1), from: { $0 * side + last }, to: { $0 * side }) {
                for r in 0..<side { copy(from: (r, 1), to: (r, 0)) }
            }
            filled.append("west")
        }
        if deadSouth {
            if !take(neighbour(-1, 0), from: { $0 }, to: { last * side + $0 }) {
                for c in 0..<side { copy(from: (last - 1, c), to: (last, c)) }
            }
            filled.append("south")
        }
        if deadNorth {
            if !take(neighbour(1, 0), from: { last * side + $0 }, to: { $0 }) {
                for c in 0..<side { copy(from: (1, c), to: (0, c)) }
            }
            filled.append("north")
        }

        guard !filled.isEmpty else { return nil }
        try FileTools.write(Data(data), to: url)
        return filled.joined(separator: ",")
    }

    /// One refresh of a neighbour at a time: 2 cells landing together may share one.
    private static let refreshing = NSLock()

    /// After a tile lands: a neighbour converted earlier, with no data across the shared edge,
    /// copied its own inner line there; that copy gets this tile's edge, so the seam agrees
    /// whichever side came first. A real edge is left alone. Returns the neighbours rewritten.
    @discardableResult
    static func refreshNeighbours(of url: URL, cell: (lat: Int, lon: Int), in directory: URL) -> [String] {
        // Read under the lock: a neighbour landing at the same moment may have just made
        // this tile's edge agree, and a copy read before that would undo it.
        refreshing.lock()
        defer { refreshing.unlock() }
        // Mapped, and only the 4 edge lines kept: the mapping goes before any file is replaced.
        let size = FileTools.size(of: url)
        guard let side = sides.first(where: { Int64($0 * $0 * 2) == size }) else { return [] }
        let last = side - 1
        // Per neighbour: its offset, its shared line, its inner line beside it, the line of
        // this tile that is the same ground and the one inside that, each as a sample index.
        typealias Line = (Int) -> Int
        let ways: [(dLat: Int, dLon: Int, edge: Line, inner: Line, own: Line, ownInner: Line)] = [
            (0, -1, { $0 * side + last }, { $0 * side + last - 1 }, { $0 * side }, { $0 * side + 1 }),
            (1, 0, { last * side + $0 }, { (last - 1) * side + $0 }, { $0 }, { side + $0 }),
            (0, 1, { $0 * side }, { $0 * side + 1 }, { $0 * side + last }, { $0 * side + last - 1 }),
            (-1, 0, { $0 }, { side + $0 }, { last * side + $0 }, { (last - 1) * side + $0 })
        ]
        func sample(_ data: Data, _ at: Int) -> (UInt8, UInt8) {
            (data[data.startIndex + at * 2], data[data.startIndex + at * 2 + 1])
        }
        // Each edge kept only where it is real: one this tile copied from inside, at a
        // coast with nothing beyond, is not to be handed on to the neighbour.
        let edges: [[(UInt8, UInt8)]?]? = {
            guard let mine = try? Data(contentsOf: url, options: .alwaysMapped), mine.count == Int(size) else {
                return nil
            }
            return ways.map { way in
                let line = (0..<side).map { sample(mine, way.own($0)) }
                let copied = (0..<side).allSatisfy { line[$0] == sample(mine, way.ownInner($0)) }
                return copied ? nil : line
            }
        }()
        guard let edges else { return [] }
        var rewritten: [String] = []
        for (index, way) in ways.enumerated() {
            guard let own = edges[index] else { continue }
            var lon = cell.lon + way.dLon
            if lon > 179 { lon -= 360 }
            if lon < -180 { lon += 360 }
            let name = HGTName.of(lat: cell.lat + way.dLat, lon: lon) + ".hgt"
            let file = directory.appendingPathComponent(name)
            // Scoped so the mapping is let go first: Windows will not replace a file still mapped.
            let fixed: [UInt8]? = {
                guard FileTools.size(of: file) == size,
                    let theirs = try? Data(contentsOf: file, options: .alwaysMapped)
                else { return nil }
                // Most neighbours landed in this same pass and agree already: asked first.
                guard !(0..<side).allSatisfy({ sample(theirs, way.edge($0)) == own[$0] }),
                    (0..<side).contains(where: { own[$0] != (0, 0) }),
                    (0..<side).allSatisfy({ sample(theirs, way.edge($0)) == sample(theirs, way.inner($0)) })
                else { return nil }
                var out = [UInt8](theirs)
                for i in 0..<side {
                    let (high, low) = own[i]
                    out[way.edge(i) * 2] = high
                    out[way.edge(i) * 2 + 1] = low
                }
                return out
            }()
            guard let fixed else { continue }
            // Best effort: one another build holds open stays as it was.
            if (try? FileTools.write(Data(fixed), to: file)) != nil { rewritten.append(name) }
        }
        return rewritten
    }
}
