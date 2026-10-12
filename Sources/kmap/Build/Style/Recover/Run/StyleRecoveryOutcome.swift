import Foundation

extension StyleRecovery {
    struct Outcome {
        let kind: ElementDumper.Kind
        let type: Int
        var witnesses: Int
        var elements: Int
        var unmatched: Int
        var ambiguous: Int
        /// The dominant tag pair, in readable form.
        var meaning: String
        var status: Status
        /// The resolutions this code was seen drawn at, coarsest to finest. A style
        /// with a second vocabulary for the zoomed-out levels shows here.
        var resolutions: [Int: Int] = [:]

        /// `16-18`, or nil where nothing was recorded.
        var zooms: String? {
            guard let low = resolutions.keys.min(), let high = resolutions.keys.max()
            else { return nil }
            return low == high ? "res \(low)" : "res \(low)–\(high)"
        }
    }
}
