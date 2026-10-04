import Foundation

/// Rules that follow a mark when the mark has to move.
extension StyleCatalog {
    /// Re-aims kmap's own repair rules onto the numbers its marks ended up on.
    ///
    /// The mark moves when a borrowed style already draws the number kmap repairs with;
    /// the rule emitting it must move too, or the links keep wearing the borrowed look.
    /// Only kmap's own rules are touched - they are the ones that name `kmap:repair`.
    @discardableResult
    static func moveRepairRules(
        _ moved: [MapElementKind: [Int: Int]],
        in directory: URL
    ) -> Int {
        var rewritten = 0
        for (kind, mapping) in moved {
            let url = directory.appendingPathComponent(kind.ruleFile)
            guard var text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var lines = text.components(separatedBy: "\n")
            var at = 0
            while at < lines.count {
                defer { at += 1 }
                guard lines[at].contains("kmap:repair") else { continue }
                for (from, to) in mapping {
                    let old = String(format: "[0x%02x ", from)
                    guard lines[at].contains(old) else { continue }
                    let moved = lines[at].replacingOccurrences(
                        of: old,
                        with: String(format: "[0x%02x ", to)
                    )
                    rewritten += 1
                    // A mark that carries no route just moves, and so does a link that
                    // found a number the receiver still routes on.
                    guard lines[at].contains("road_class="),
                        !TypAugment.routableLines.contains(to)
                    else {
                        lines[at] = moved
                        continue
                    }
                    // Only the plain road numbers route, and the borrowed style has
                    // taken every one. The link keeps the number it can route on -
                    // wearing that style's look - and the dashes are drawn over it as a
                    // second line of their own, the way a style draws a casing.
                    lines[at] =
                        lines[at].contains(" continue")
                        ? lines[at]
                        : lines[at].replacingOccurrences(of: "]", with: " continue]")
                    var paint = moved
                    for attribute in ["road_class", "road_speed"] {
                        while let mark = paint.range(
                            of: "\(attribute)=[0-9]+",
                            options: .regularExpression
                        ) {
                            paint.removeSubrange(mark)
                        }
                    }
                    while paint.contains("  ") {
                        paint = paint.replacingOccurrences(of: "  ", with: " ")
                    }
                    paint = paint.replacingOccurrences(of: " ]", with: "]")
                    lines.insert(paint, at: at + 1)
                    at += 1
                }
            }
            guard rewritten > 0 else { continue }
            text = lines.joined(separator: "\n")
            try? FileTools.write(text, to: url)
        }
        return rewritten
    }
}
