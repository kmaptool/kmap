import Foundation

extension StyleRecovery {
    struct Report {
        var frame = BBox.empty
        var extracts: [URL] = []
        var elements = 0
        /// The share of the map's data lying under the extracts read.
        var share = 0.0
        /// Where the map draws, as the run measured it.
        var drawn: RegionSuggestion.DrawnGround?
        /// What the run left unsure and where the rest of the map draws it: set where
        /// more ground was asked about and the map was not read whole.
        var remainder: Remainder?
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

        /// How many of the codes an earlier run left unsettled this one settled: a meaning
        /// found for them, whether or not a rule of ours draws it.
        func settled(of left: Remainder) -> Int {
            outcomes.values.filter {
                ($0.status == .resolved || $0.status == .noRule)
                    && left.seen[Evidence.slot($0.kind, $0.type)] != nil
            }.count
        }
    }
}
