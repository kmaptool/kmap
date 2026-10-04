import Foundation

extension TileSplitter {
    /// A block's ways by tile, each tile's as 1 run in the block's order.
    struct WayBuckets {
        private(set) var runs: TileRuns
        private(set) var chunks: [PBFWriter.WayChunk] = []
        private var strings: [RunStrings] = []

        init(tiles: Int) { runs = TileRuns(tiles: tiles) }

        var tileCount: Int { runs.tileCount }
        var count: Int { runs.count }
        var tiles: [UInt16] { runs.tiles }

        mutating func add(
            id: Int64,
            refs: ArraySlice<Int64>,
            keys: ArraySlice<Int32>,
            values: ArraySlice<Int32>,
            block: OSMBlock,
            to tile: UInt16
        ) {
            let (run, opened) = runs.run(for: tile)
            if run == chunks.count {
                chunks.append(PBFWriter.WayChunk())
                strings.append(RunStrings())
            }
            if opened { strings[run].open(for: block) }
            chunks[run].ids.append(id)
            chunks[run].refs.append(contentsOf: refs)
            chunks[run].refEnds.append(Int32(chunks[run].refs.count))
            for (key, value) in zip(keys, values) {
                let keyPlace = strings[run].place(of: key, in: block, among: &chunks[run].strings)
                let valuePlace = strings[run].place(of: value, in: block, among: &chunks[run].strings)
                chunks[run].tags.append(keyPlace)
                chunks[run].tags.append(valuePlace)
            }
            chunks[run].tagEnds.append(Int32(chunks[run].tags.count))
        }

        /// Empties the runs, each onto fresh storage: the storage went to its tile's writer
        /// and stays there until the batch is written. Nothing is reserved: a run's number
        /// names another tile in the next block, and its size would be carried there.
        mutating func clear() {
            for run in 0..<runs.count { chunks[run] = PBFWriter.WayChunk() }
            runs.clear()
        }
    }
}
