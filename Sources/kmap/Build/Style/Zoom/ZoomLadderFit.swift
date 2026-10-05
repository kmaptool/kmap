import Foundation

/// Rules fitted to the zoom ladder a build draws at.
extension StyleCatalog {
    /// The resolutions a levels profile draws at, tiles and overview submap together:
    /// `0:24, 1:22` and `4:17, 5:16` give 24, 22, 17, 16.
    static func rungs(of levels: LevelsProfile) -> [Int] {
        (levels.levels + ", " + levels.overviewLevels)
            .split(separator: ",")
            .compactMap {
                Int(
                    $0.split(separator: ":").last?
                        .trimmingCharacters(in: .whitespaces) ?? ""
                )
            }
            .sorted()
    }

    /// Fits every band of zooms in a style onto the ladder this build actually has.
    ///
    /// A borrowed style's bands come from its own map, whose ladder may hold rungs this
    /// build does not: a stroke pinned to `resolution 20-20` draws nothing where the
    /// ladder steps 21, 19. Each end is moved to the nearest rung there is, so the
    /// stroke lands on the zoom closest to where its author put it.
    static func fitBands(to ladder: [Int], in directory: URL) throws -> Int {
        guard !ladder.isEmpty else { return 0 }
        func nearest(_ value: Int) -> Int {
            ladder.min { a, b in
                let da = abs(a - value), db = abs(b - value)
                return da == db ? a < b : da < db
            } ?? value
        }
        var fitted = 0
        for name in ["lines", "polygons", "points"] {
            let url = directory.appendingPathComponent(name)
            guard var text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // A ladder's coarsest stroke reaches as far out as its rule does. The bands
            // come from the borrowed map, whose own ladder stops where its tiles stop;
            // ours goes further out, and a motorway that vanishes when you zoom out is
            // not what either style means. The rule says how far: the zoom plan has
            // already lowered the roads meant to survive the far view.
            text = reachOfLadders(in: text)
            var out: [String] = []
            for line in text.components(separatedBy: "\n") {
                guard
                    let range = line.range(
                        of: "resolution [0-9]+-[0-9]+",
                        options: .regularExpression
                    )
                else {
                    out.append(line)
                    continue
                }
                let numbers = line[range].split(separator: " ")[1].split(separator: "-")
                guard numbers.count == 2, let low = Int(numbers[0]),
                    let high = Int(numbers[1])
                else { out.append(line); continue }
                // A band with a rung inside it already draws where it should.
                if ladder.contains(where: { $0 >= low && $0 <= high }) {
                    out.append(line)
                    continue
                }
                let fittedLow = nearest(low), fittedHigh = nearest(high)
                out.append(
                    line.replacingCharacters(
                        in: range,
                        with: "resolution \(min(fittedLow, fittedHigh))-\(max(fittedLow, fittedHigh))"
                    )
                )
                fitted += 1
            }
            text = out.joined(separator: "\n")
            try FileTools.write(text, to: url)
        }
        return fitted
    }

    /// Extends each ladder's coarsest stroke down to the zoom its own rule reaches.
    ///
    /// The strokes of one rule sit directly above it, sharing its condition; the rule
    /// itself carries no band. Where the rule draws further out than its coarsest
    /// stroke, that stroke follows it down, so the road keeps its borrowed look at
    /// every zoom rather than falling back to the plain line.
    static func reachOfLadders(in text: String) -> String {
        func condition(of line: String) -> String? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("[0x"), !trimmed.hasPrefix("#") else { return nil }
            let cut =
                trimmed.firstIndex(of: "{") ?? trimmed.firstIndex(of: "[")
                ?? trimmed.endIndex
            let head = String(trimmed[..<cut]).trimmingCharacters(in: .whitespaces)
            return head.isEmpty ? nil : head
        }
        func band(of line: String) -> (low: Int, high: Int)? {
            guard
                let found = line.range(
                    of: "resolution [0-9]+-[0-9]+",
                    options: .regularExpression
                )
            else { return nil }
            let parts = line[found].split(separator: " ")[1].split(separator: "-")
            guard parts.count == 2, let low = Int(parts[0]), let high = Int(parts[1])
            else { return nil }
            return (low, high)
        }
        func plainResolution(of line: String) -> Int? {
            guard band(of: line) == nil,
                let found = line.range(
                    of: "resolution [0-9]+",
                    options: .regularExpression
                )
            else { return nil }
            return Int(line[found].split(separator: " ")[1])
        }

        var lines = text.components(separatedBy: "\n")
        var at = 0
        while at < lines.count {
            guard let head = condition(of: lines[at]) else { at += 1; continue }
            var end = at
            while end + 1 < lines.count, condition(of: lines[end + 1]) == head { end += 1 }
            defer { at = end + 1 }
            guard end > at else { continue }
            // The rule of the group: the one drawn without a band.
            guard let reach = lines[at...end].compactMap(plainResolution).min()
            else { continue }
            var lowest: (index: Int, low: Int, high: Int)?
            for index in at...end {
                guard let band = band(of: lines[index]) else { continue }
                if lowest == nil || band.low < lowest!.low {
                    lowest = (index, band.low, band.high)
                }
            }
            guard let lowest, reach < lowest.low else { continue }
            lines[lowest.index] = lines[lowest.index].replacingOccurrences(
                of: "resolution [0-9]+-[0-9]+",
                with: "resolution \(reach)-\(lowest.high)",
                options: .regularExpression
            )
        }
        return lines.joined(separator: "\n")
    }
}
