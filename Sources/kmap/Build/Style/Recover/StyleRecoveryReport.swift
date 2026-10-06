import Foundation

extension StyleRecovery {
    struct Report {
        var frame = BBox.empty
        var extracts: [URL] = []
        var elements = 0
        /// key -> outcome, sorted for printing by the caller.
        var outcomes: [String: Outcome] = [:]
        /// The recovered style: their pictures on kmap's numbers. A TYP that builds,
        /// which is what a recovery is for.
        var style = ""
        /// The code page of their TYP, which `style`'s labels are in.
        var codePage: Int?
        /// What their style draws and kmap has no number for, worst first.
        var uncovered: [StylePort.Ported] = []
        /// How many of our numbers took a picture, by kind, for the report.
        var ported: [MapElementKind: Int] = [:]
        /// Our numbers several looks of theirs wanted: the winner with its rivals.
        var contested: [StylePort.Ported] = []
        /// The reassignment list. Nothing needs it to build; it is for the style
        /// editor, and for a style still kept on the map's own numbers.
        var sheet = ""
        /// What the map draws each meaning with: tag -> code key -> identified sources.
        /// The raw material of `recover-check`, which compares two maps tag by tag.
        var codesByTag: [String: [String: Int]] = [:]
        /// The ground each meaning covers under each code, in map units squared.
        var areaByTag: [String: [String: Double]] = [:]
        /// How many objects of each meaning the searched ground holds at all - so a tag
        /// the ground never carries is not reported as a map's omission.
        var groundTags: [String: Int] = [:]
    }

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

    enum Status: String {
        /// Two or more agreeing identifications, and a rule line found: in the sheet.
        case resolved
        /// One clean identification: in the sheet, flagged for review.
        case singleWitness = "single-witness"
        /// Witnesses agree but no default rule emits this meaning; decided by hand.
        case noRule = "no-rule"
        /// Witnesses disagree beyond the threshold; decided by hand.
        case mixed
        /// Nothing identified on the ground that was searched.
        case noEvidence = "no-evidence"
    }
}
