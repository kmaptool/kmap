import Foundation

extension Contours {
    /// One traced line at one elevation.
    struct Line {
        var elevation: Int
        var points: [(lat: Double, lon: Double)]
        var closed: Bool
    }

    /// The most vertices one way may carry, matching pyhgtmap's limit.
    static let maxPoints = 2000

    /// Splits lines longer than `maxPoints`. Each piece repeats the vertex it shares with
    /// the next, so the line stays joined.
    static func split(_ lines: [Line]) -> [Line] {
        var out: [Line] = []
        for line in lines {
            guard line.points.count > maxPoints else {
                out.append(line)
                continue
            }
            var at = 0
            while at < line.points.count - 1 {
                let end = min(at + maxPoints, line.points.count)
                out.append(
                    Line(
                        elevation: line.elevation,
                        points: Array(line.points[at..<end]),
                        closed: false
                    )
                )
                at = end - 1
            }
        }
        return out
    }
}
