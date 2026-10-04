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

        mutating func clear() {
            for run in 0..<runs.count {
                let held = chunks[run]
                chunks[run] = PBFWriter.WayChunk()
                chunks[run].ids.reserveCapacity(held.ids.count)
                chunks[run].refEnds.reserveCapacity(held.ids.count)
                chunks[run].refs.reserveCapacity(held.refs.count)
                chunks[run].tagEnds.reserveCapacity(held.ids.count)
                chunks[run].tags.reserveCapacity(held.tags.count)
                chunks[run].strings.reserveCapacity(held.strings.count)
            }
            runs.clear()
        }
    }
}
