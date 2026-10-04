import Foundation

/// The zoom ladder: which map detail level is shown at which zoom. More levels means
/// smoother zooming and larger tiles.
struct LevelsProfile: Equatable {
    let id: String
    /// Catalogue keys rather than text; see `LabelLanguage`.
    let nameKey: String
    let levels: String
    let overviewLevels: String
    let noteKey: String

    var name: String { t(nameKey) }
    var note: String { t(noteKey) }

    /// mkgmap's default: four levels, smaller maps, visible jumps when zooming.
    static let standard = LevelsProfile(
        id: "standard",
        nameKey: "Standard (4 levels)",
        levels: "0:24, 1:22, 2:20, 3:18",
        overviewLevels: "4:17, 5:16, 6:15, 7:14, 8:13",
        noteKey: "mkgmap's default — smaller maps, coarser zoom steps"
    )

    /// Seven tile levels, `0:24` down to `6:17`; mkgmap refuses a ninth ("Too many levels,
    /// the maximum is 8"). Rungs are spent at the coarse end so far zooms stay drawn: on a
    /// receiver, rung 24 is about 300 m, 23 about 600 m, 22 about 1.2 km, 21 about 3 km.
    static let smooth = LevelsProfile(
        id: "smooth",
        nameKey: "Smooth (8 levels)",
        levels: "0:24, 1:23, 2:22, 3:21, 4:19, 5:18, 6:17",
        // Level 16 belongs to the overview submap, not to the tiles: a receiver re-renders
        // per map holding data at the new level, so one submap replaces many tiles there.
        overviewLevels: "7:16, 8:15, 9:14, 10:13",
        noteKey: "smooth zoom close in; the overview never goes empty"
    )

    static let all = [standard, smooth]

    var levelCount: Int { levels.split(separator: ",").count }

    /// DEM spacings for the coarse end of the ladder, one per zoom level, finest first.
    /// Valid only together with `--overview-dem-dist` in StageCompile: the coarsest entry
    /// sets the farthest zoom that still gets hillshading.
    private static let demBands = [26496, 52992, 106048]
    /// A source's own spacing in the same units: one arc second, and three.
    private static let spacingOneArcSecond = 3312.0, spacingThreeArcSeconds = 9936.0
    /// mkgmap rounds a spacing to a multiple of this anyway.
    private static let demDistStep = 16

    func demDists(oneArcSecond: Bool) -> String {
        // The fine end climbs geometrically from the source's own spacing to the first
        // named band, so the ladder stays monotonic whatever its length and source.
        let start =
            oneArcSecond
            ? LevelsProfile.spacingOneArcSecond
            : LevelsProfile.spacingThreeArcSeconds
        let head = max(0, levelCount - LevelsProfile.demBands.count)
        let span = Double(LevelsProfile.demBands[0]) / start
        var out: [Int] = []
        for step in 0..<head {
            let value = start * pow(span, Double(step) / Double(head))
            out.append(
                Int((value / Double(LevelsProfile.demDistStep)).rounded())
                    * LevelsProfile.demDistStep
            )
        }
        return (out + LevelsProfile.demBands.suffix(levelCount - head))
            .map(String.init).joined(separator: ",")
    }
}
