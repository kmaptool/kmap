import Foundation

/// Where each family sits on the ladder, read out of the rules that will be compiled
/// rather than from a table, so it cannot go stale. One pass over the rule files.
/// With no materialized style on disk the survey is empty.
struct ZoomSurvey {
    /// Per family: the rungs its rules occupy, finest first, and how many rules there are.
    struct Spread: Equatable {
        var finest: Int
        var coarsest: Int
        var rules: Int
    }

    private(set) var spreads: [String: Spread] = [:]
    let rungs: ZoomRungs

    var isEmpty: Bool { spreads.isEmpty }

    func spread(_ family: ZoomFamily) -> Spread? { spreads[family.id] }

    /// Reads a materialized style. `directory` is the rule set a build would compile.
    init(styleAt directory: URL, levels: LevelsProfile) {
        rungs = ZoomRungs(levels: levels.levels)
        guard !rungs.isEmpty else { return }

        for file in Set(ZoomFamily.all.flatMap(\.files)).sorted() {
            guard let text = try? String(contentsOf: directory.appendingPathComponent(file),
                                         encoding: .utf8) else { continue }
            for rule in ZoomRuleScan.rules(in: text.components(separatedBy: "\n")) {
                guard let family = ZoomFamily.all.first(where: {
                          $0.claims(rule.condition, in: file)
                      }),
                      let found = ZoomRuleScan.resolution(in: rule.type),
                      let rung = rungs.rung(forResolution: found.value) else { continue }

                var spread = spreads[family.id] ?? Spread(finest: rung, coarsest: rung, rules: 0)
                spread.finest = min(spread.finest, rung)
                spread.coarsest = max(spread.coarsest, rung)
                spread.rules += 1
                spreads[family.id] = spread
            }
        }
    }

    /// The move that puts a family's start on `rung`. The screen offers rungs and stores
    /// moves, which keep their meaning when a later mkgmap shifts a rule.
    func shift(putting family: ZoomFamily, onRung rung: Int) -> Int? {
        guard let spread = spread(family) else { return nil }
        return rung - spread.coarsest
    }

    /// The same rung as a sentence about a family: "starts at rung 2 · 1.2 km". One
    /// localization key rather than a preposition glued to `rungLabel`, since an inflecting
    /// language cannot assemble the phrase from parts.
    func startsAt(rung: Int) -> String {
        let at = clamp(rung)
        let scale = ZoomRungs.scale(bits: rungs.bits[at]).map { "  ·  " + $0 } ?? ""
        return t("from level %d", at) + scale
    }

    /// The far end of a window, as a sentence: "and stops at rung 3 · 3 km". One
    /// localization key, for the reason `startsAt` is one.
    func stopsAt(rung: Int) -> String {
        let at = clamp(rung)
        let scale = ZoomRungs.scale(bits: rungs.bits[at]).map { "  ·  " + $0 } ?? ""
        return t("and stops at level %d", at) + scale
    }

    /// How a rung reads in a list of them: its number, and its scale where one is known.
    /// A rung with no known scale says its number alone; the mapping from bits to a scale
    /// bar is irregular and is never interpolated.
    func rungLabel(_ rung: Int) -> String {
        let at = clamp(rung)
        guard let scale = ZoomRungs.scale(bits: rungs.bits[at]) else {
            return t("level %d", at)
        }
        return t("level %d", at) + "  ·  " + scale
    }

    private func clamp(_ rung: Int) -> Int {
        max(0, min(rungs.bits.count - 1, rung))
    }


}
