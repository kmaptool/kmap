import Foundation

extension ImgElements {
    /// How much of a map's detail-level drawing lies within the boxes, weighed by the RGN
    /// bytes of each subdivision. A tile can stretch over the empty ground between 2
    /// distant regions, so its area says nothing of where its data is. Nil where no tile
    /// reads.
    static func dataShare(of img: URL, within boxes: [BBox]) -> Double? {
        let grounds = boxes.map(Ground.init)
        var total = 0.0
        var held = 0.0
        let directory = ImgContainer.directory(of: img)
        for tre in directory where tre.ext.uppercased() == "TRE" {
            guard let data = ImgContainer.read(tre, from: img), let tree = try? Tree(data, tile: tre.name)
            else { continue }
            for division in tree.subdivisions where division.level == 0 {
                let bytes =
                    max(0, division.rgnEnd - division.rgnStart) + max(0, division.extAreasSize)
                    + max(0, division.extLinesSize) + max(0, division.extPointsSize)
                guard bytes > 0 else { continue }
                total += Double(bytes)
                held += Double(bytes) * division.share(within: grounds)
            }
        }
        return total > 0 ? held / total : nil
    }
}
