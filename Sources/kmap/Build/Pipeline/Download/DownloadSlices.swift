import Foundation

/// How several downloads share one stage: each one's slice of the bar, and the time left
/// for all of them.
extension BuildPipeline {
    /// Each region's slice of the one download bar, which advances monotonically across
    /// all regions of a build. A slice is as wide as the region is large, so the bar moves
    /// at the pace of the bytes. When any size is unknown the slices are equal.
    struct DownloadSlices {
        private let starts: [Double]
        private let widths: [Double]

        init(sizes: [Int64]) {
            let total = sizes.reduce(0, +)
            let sized = total > 0 && !sizes.contains { $0 <= 0 }
            widths =
                sized
                ? sizes.map { Double($0) / Double(total) }
                : Array(repeating: 1 / Double(max(1, sizes.count)), count: sizes.count)
            var start = 0.0
            starts = widths.map { width in
                defer { start += width }
                return start
            }
        }

        static func equal(_ count: Int) -> DownloadSlices {
            DownloadSlices(sizes: Array(repeating: 0, count: count))
        }

        /// A region's own 0...1 progress, as a position on the whole bar.
        func fraction(region index: Int, at f: Double) -> Double {
            guard starts.indices.contains(index) else { return 0 }
            return starts[index] + widths[index] * min(1, max(0, f))
        }
    }

    /// Seconds until the whole stage is done: what is left of this file and every byte
    /// still to be fetched after it, at the rate this file is arriving. Nil while the
    /// file's own estimate has not settled.
    static func stageSecondsLeft(
        fileSecondsLeft: Double,
        rate: Double,
        bytesAfterThisFile: Int64
    ) -> Double? {
        guard fileSecondsLeft.isFinite, rate > 0 else { return nil }
        return fileSecondsLeft + Double(max(0, bytesAfterThisFile)) / rate
    }
}
