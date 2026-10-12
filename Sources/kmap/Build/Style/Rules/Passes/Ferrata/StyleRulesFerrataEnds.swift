import Foundation

/// An icon at each end of a via ferrata, on the nodes the annotate pass marks. Drawn only
/// where the build's TYP has a picture for it.
extension StyleCatalog {
    static let ferrataEndCode = 0x660a
    /// The climber kmap puts on crags and climbing gyms, which a style without a via
    /// ferrata end of its own lends to the ends.
    static let climbingCode = 0x2c0e
    static let ferrataEndRule = "kmap:ferrata_end=yes [0x660a resolution 22 continue]"
    /// How every end rule starts, at whatever number and resolution.
    static let ferrataEndHead = "kmap:ferrata_end=yes ["

    /// First and going on, so a node that is also something else keeps its own icon too.
    func addFerrataEndRule(in directory: URL, log: Log) throws {
        let marker = "# --- kmap: via ferrata ends"
        guard
            try prependRules(
                "\n\n\(marker) ---------------------------------------------\n\(Self.ferrataEndRule)\n\n",
                marked: marker,
                toFile: "points",
                in: directory
            )
        else { return }
        log.append("via ferrata ends marked")
    }

    /// Takes the via ferrata end icon out of a build's rules, at whatever resolution a
    /// zoom plan put it. A rule a person aimed at another icon by hand stays.
    static func dropFerrataEnds(in directory: URL) throws {
        let url = directory.appendingPathComponent("points")
        guard let text = try? String(contentsOf: url, encoding: .utf8), text.contains(ferrataEndHead) else { return }
        let kept = text.components(separatedBy: "\n").filter {
            !$0.hasPrefix(ferrataEndHead) || $0.contains(RuleReassignment.mark)
        }
        try FileTools.write(kept.joined(separator: "\n"), to: url)
    }
}
