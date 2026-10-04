import Foundation

extension TileSplitter {
    /// A block's nodes by tile, each tile's as 1 run in the block's order.
    struct NodeBuckets {
        private(set) var runs: TileRuns
        private(set) var chunks: [PBFWriter.NodeChunk] = []
        private var strings: [RunStrings] = []

        init(tiles: Int) { runs = TileRuns(tiles: tiles) }

        var tileCount: Int { runs.tileCount }
        var count: Int { runs.count }
        var tiles: [UInt16] { runs.tiles }

        mutating func add(
            id: Int64,
            lat: Double,
            lon: Double,
            tags: ArraySlice<Int32>,
            block: OSMBlock,
            to tile: UInt16
        ) {
            let (run, opened) = runs.run(for: tile)
            if run == chunks.count {
                chunks.append(PBFWriter.NodeChunk())
                strings.append(RunStrings())
            }
            if opened { strings[run].open(for: block) }
            chunks[run].ids.append(id)
            chunks[run].lats.append(lat)
            chunks[run].lons.append(lon)
            var index = tags.startIndex
            while index + 1 < tags.endIndex {
                let key = strings[run].place(of: tags[index], in: block, among: &chunks[run].strings)
                let value = strings[run].place(of: tags[index + 1], in: block, among: &chunks[run].strings)
                chunks[run].tags.append(key)
                chunks[run].tags.append(value)
                index += 2
            }
            chunks[run].tagEnds.append(Int32(chunks[run].tags.count))
        }

        /// Empties the runs, each onto fresh storage: the storage went to its tile's writer
        /// and stays there until the batch is written. Nothing is reserved: a run's number
        /// names another tile in the next block, and its size would be carried there.
        mutating func clear() {
            for run in 0..<runs.count { chunks[run] = PBFWriter.NodeChunk() }
            runs.clear()
        }
    }
}
