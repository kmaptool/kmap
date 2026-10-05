import Foundation

/// Collecting the summits with a height from the extracts.
extension BurnPeaks {
    /// Every summit in the extracts, as one list.
    static func peaks(in urls: [URL], shouldStop: @escaping () -> Bool = { false }) throws -> [Peak] {
        var found: [Peak] = []
        for url in urls {
            for part in try PBFReader(url: url, shouldStop: shouldStop).readConcurrently(make: { PeakScan() }) {
                found.append(contentsOf: part.peaks)
            }
        }
        // Sorted, on everything a peak holds: the workers take blocks in any order.
        found.sort { ($0.lat, $0.lon, $0.name, $0.ele) < ($1.lat, $1.lon, $1.name, $1.ele) }
        return found
    }

    /// Every summit node with a usable height.
    private struct PeakScan: OSMSink {
        let wantedParts: OSMParts = .nodes

        var peaks: [Peak] = []

        mutating func node(
            id: Int64,
            lat: Double,
            lon: Double,
            tags: ArraySlice<Int32>,
            block: OSMBlock
        ) {
            var natural: String?, ele: String?, eleFeet: String?, name = ""
            var at = tags.startIndex
            while at + 1 < tags.endIndex {
                switch block.text(Int(tags[at])) {
                case "natural": natural = block.text(Int(tags[at + 1]))
                case "ele": ele = block.text(Int(tags[at + 1]))
                case "ele:ft": eleFeet = block.text(Int(tags[at + 1]))
                case "name": name = block.text(Int(tags[at + 1]))
                default: break
                }
                at += 2
            }
            guard natural == "peak" || natural == "volcano",
                let height = BurnPeaks.metres(ele) ?? BurnPeaks.metres(feet: eleFeet)
            else { return }
            peaks.append(Peak(lat: lat, lon: lon, ele: height, name: name))
        }
    }
}
