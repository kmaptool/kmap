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

        /// Empties the runs. The storage went to the tile's writer with the run, which
        /// keeps it until the batch is written, so each run starts on storage of its own,
        /// sized by what it held: keeping the capacity would copy the largest block's.
        mutating func clear() {
            for run in 0..<runs.count {
                let held = chunks[run]
                chunks[run] = PBFWriter.NodeChunk()
                chunks[run].ids.reserveCapacity(held.ids.count)
                chunks[run].lats.reserveCapacity(held.ids.count)
                chunks[run].lons.reserveCapacity(held.ids.count)
                chunks[run].tagEnds.reserveCapacity(held.ids.count)
                chunks[run].tags.reserveCapacity(held.tags.count)
                chunks[run].strings.reserveCapacity(held.strings.count)
            }
            runs.clear()
        }
    }
}
