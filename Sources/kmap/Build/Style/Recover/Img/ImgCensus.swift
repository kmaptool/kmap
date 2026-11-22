import Foundation

extension ImgElements {
    /// Every detail-level subdivision with elements off all of `grounds`, each with its
    /// count of every code among those: what the run reading `grounds` did not see. The
    /// detail level alone, where an object drawn again at a coarser one is still 1
    /// witness. Tiles are read across the cores; a tile or a subdivision that does not read
    /// is left out.
    static func census(of img: URL, off grounds: [Ground], stop: StopFlag) throws -> [Tally] {
        let directory = ImgContainer.directory(of: img)
        let tiles = directory.filter { $0.ext.uppercased() == "TRE" }
        let drawings = Dictionary(
            directory.filter { $0.ext.uppercased() == "RGN" }.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let tallies = Lanes.map(tiles.count) { at -> [Tally] in
            guard !stop.isRaised, let rgn = drawings[tiles[at].name],
                let treData = ImgContainer.read(tiles[at], from: img),
                let tree = try? Tree(treData, tile: tiles[at].name),
                let rgnData = ImgContainer.read(rgn, from: img),
                let region = try? Region(rgnData, tile: tiles[at].name)
            else { return [] }
            var out: [Tally] = []
            for division in tree.subdivisions where division.level == 0 {
                if stop.isRaised { return [] }
                // Only a subdivision near the ground can hold what the run read; one an
                // outline holds whole was read whole.
                let near = grounds.contains { division.near($0) }
                let reach = near ? reach(of: division, on: grounds) : (whole: false, asked: [])
                if reach.whole { continue }
                var codes: [Int: Int] = [:]
                let read: Void? = try? region.read(division, extendedAreasAndPoints: true, tile: tiles[at].name) {
                    kind,
                    type,
                    coords in
                    if coords.contains(where: { c in reach.asked.contains { $0.contains(c) } }) { return }
                    codes[Evidence.slot(kind, type), default: 0] += 1
                }
                if read != nil, !codes.isEmpty { out.append(Tally(box: division.box, codes: codes)) }
            }
            return out
        }
        if stop.isRaised { throw CancellationError() }
        return tallies.flatMap { $0 }
    }
}
