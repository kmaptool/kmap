import Foundation

// MARK: The tiles

extension GEDTM30 {
    /// Where a tile's bytes are, and how many. A tile of 0 bytes is all nodata.
    struct Span: Sendable, Equatable {
        let offset: Int64
        let count: Int
    }

    /// Index entries further apart are read separately, so distant regions do not pull
    /// the index between them.
    static let indexGap = 64

    /// A longer span means a damaged index.
    static let largestSpan = 64 << 20

    /// Index runs read at once.
    private static let indexLanes = 6

    /// Spans of these tiles, from the index in runs of nearby entries.
    static func spans(of tiles: Set<Int>, in layout: Layout, read: @escaping Read) async throws -> [Int: Span] {
        let order = TIFF.Order(bigEndian: layout.bigEndian)
        let runs = runs(of: tiles.filter { $0 >= 0 && $0 < layout.tileCount })
        let out = Locked<[Int: Span]>([:])
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            func launch() {
                let run = runs[next]
                next += 1
                group.addTask {
                    let first = run[0], length = run[run.count - 1] - first + 1
                    let (offsetSize, countSize) = (layout.offsetSize, layout.countSize)
                    async let offsetsRead = read(layout.offsetsAt + Int64(first * offsetSize), length * offsetSize)
                    async let countsRead = read(layout.countsAt + Int64(first * countSize), length * countSize)
                    let (offsets, counts) = try await (offsetsRead, countsRead)
                    guard offsets.count == length * offsetSize, counts.count == length * countSize else {
                        throw Trouble.truncated
                    }
                    var found: [Int: Span] = [:]
                    for tile in run {
                        let offset = order.int(offsets, (tile - first) * offsetSize, offsetSize)
                        let count = order.int(counts, (tile - first) * countSize, countSize)
                        guard (0...Int(mostFileBytes)).contains(offset), (0...largestSpan).contains(count) else {
                            throw Trouble.notTIFF
                        }
                        found[tile] = Span(offset: Int64(offset), count: count)
                    }
                    out.withLock { $0.merge(found) { a, _ in a } }
                }
            }
            while next < runs.count && next < indexLanes { launch() }
            for try await _ in group where next < runs.count { launch() }
        }
        return out.withLock { $0 }
    }

    /// The tiles sorted and cut wherever 2 neighbours are more than `indexGap` apart.
    static func runs(of tiles: Set<Int>) -> [[Int]] {
        var out: [[Int]] = []
        for tile in tiles.sorted() {
            if let last = out.last?.last, tile - last <= indexGap {
                out[out.count - 1].append(tile)
            } else {
                out.append([tile])
            }
        }
        return out
    }

    /// A tile's samples from its bytes as served: inflated, the predictor undone.
    static func decode(_ compressed: Data, layout: Layout) throws -> [Float] {
        let tile = layout.tile
        var raw = [UInt8](unsafeUninitializedCapacity: tile.bytes) { _, filled in filled = tile.bytes }
        do {
            try compressed.withUnsafeBytes { input in
                try raw.withUnsafeMutableBufferPointer { out in
                    try Deflate.inflate(input, into: out, expecting: tile.bytes)
                }
            }
        } catch {
            throw Trouble.truncated
        }
        return tile.floats(from: &raw)
    }

    /// Writes 1 cell as `.hgt`, a node per pixel. `sample` yields a decoded tile, nil for
    /// all nodata. Returns the ground nodes; 0 is sea, and nothing is written.
    func write(
        lat: Int,
        lon: Int,
        layout: Layout,
        to url: URL,
        sample: (Int) throws -> [Float]?
    ) throws -> Int {
        let n = nodes
        let (row0, column0) = try layout.corner(lat: lat, lon: lon)
        var out = [UInt8](repeating: 0, count: n * n * 2)
        var ground = 0
        for tile in try layout.tiles(lat: lat, lon: lon, nodes: n) {
            guard let samples = try sample(tile) else { continue }
            let top = tile / layout.tilesAcross * layout.tileHeight
            let left = tile % layout.tilesAcross * layout.tileWidth
            // The part of the cell this tile holds, in cell nodes.
            let firstRow = max(0, top - row0), lastRow = min(n - 1, top + layout.tileHeight - 1 - row0)
            let firstColumn = max(0, left - column0)
            let lastColumn = min(n - 1, left + layout.tileWidth - 1 - column0)
            guard firstRow <= lastRow, firstColumn <= lastColumn else { continue }
            samples.withUnsafeBufferPointer { samples in
                out.withUnsafeMutableBufferPointer { out in
                    for r in firstRow...lastRow {
                        let line = samples.baseAddress! + (row0 + r - top) * layout.tileWidth + (column0 - left)
                        ground += HGTConversion.storeHeights(
                            line + firstColumn,
                            count: lastColumn - firstColumn + 1,
                            nodata: layout.nodata,
                            into: out.baseAddress! + (r * n + firstColumn) * 2
                        )
                    }
                }
            }
        }
        guard ground > 0 else { return 0 }
        try FileTools.write(Data(out), to: url)
        return ground
    }
}
