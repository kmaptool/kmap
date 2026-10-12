import Foundation

/// The cursor picks a plain line before a road, so each road gets a plain twin it can pick.
extension StyleCatalog {
    /// Splits each road rule: the road on the finest level with `continue`, then a twin
    /// rule with the same condition on the road's levels.
    ///
    /// - Parameters:
    ///   - choose: gets the codes that can be twinned and all line codes, returns road code
    ///     to twin code.
    ///   - borrowing: by road code, the meanings whose twin takes another road code's twin.
    /// - Returns: the number of rules split.
    @discardableResult
    static func addRoadTwins(
        finest: Int,
        in directory: URL,
        borrowing: [Int: [(tag: String, as: Int)]] = [:],
        choose: (_ roads: Set<Int>, _ taken: Set<Int>) -> [Int: Int]
    ) throws -> Int {
        let url = directory.appendingPathComponent("lines")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        let lines = TextLines.keepingTrailingBlank(text)
        guard let scan = RoadTwinScan(lines: lines, finest: finest, root: directory) else { return 0 }
        guard !scan.twinnable.isEmpty else { return 0 }
        let twins = choose(scan.twinnable, scan.taken).filter { scan.twinnable.contains($0.key) }
        guard !twins.isEmpty else { return 0 }
        let (out, split) = scan.split(lines, twins: twins, borrowing: borrowing, finest: finest)
        guard split > 0 else { return 0 }
        try FileTools.write(out.joined(separator: "\n"), to: url)
        return split
    }
}
