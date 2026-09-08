import Foundation

extension StyleCatalog {

    /// Draws each family only on the rungs the plan gives it: `resolution` is the floor
    /// and the range form adds a ceiling where there is one. Every rule of a family moves
    /// by the same amount, keeping its spread. Runs after the hides, which match exactly.
    func applyZoomPlan(_ plan: ZoomPlan, levels: LevelsProfile,
                       in directory: URL, log: Log) throws {
        guard plan.movesAnything else { return }
        let rungs = ZoomRungs(levels: levels.levels)
        guard !rungs.isEmpty else {
            log.warn("the zoom plan was skipped: \(levels.name) has no readable rungs")
            return
        }

        let asked = ZoomFamily.all.filter { plan.window($0) != nil }
        let measured = ZoomSurvey(styleAt: directory, levels: levels)
        var counts: [String: Int] = [:]

        for file in Set(asked.flatMap(\.files)).sorted() {
            let url = directory.appendingPathComponent(file)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }

            var lines = text.components(separatedBy: "\n")
            for rule in ZoomRuleScan.rules(in: lines) {
                // The OWNER first, from the full list, and only then the plan: matching
                // against the asked families alone lets one of them claim a rule that
                // belongs to a family not asked for.
                guard let family = ZoomFamily.all.first(where: {
                          $0.claims(rule.condition, in: file)
                      }),
                      asked.contains(where: { $0.id == family.id }),
                      let window = plan.window(family),
                      let spread = measured.spread(family),
                      let found = ZoomRuleScan.resolution(in: rule.type),
                      let was = rungs.rung(forResolution: found.value) else { continue }

                // The family as a whole is moved so its first appearance lands on the
                // window's coarse end; this rule keeps its own place within that.
                let moved = was + (window.rungs.upperBound - spread.coarsest)
                let start = min(max(moved, window.rungs.lowerBound), window.rungs.upperBound)
                guard let text = resolution(from: start, to: window.rungs.lowerBound,
                                            on: rungs) else { continue }
                let type = rule.type.replacingCharacters(in: found.range, with: text)
                guard type != rule.type else { continue }
                lines[rule.line] = lines[rule.line]
                    .replacingCharacters(in: rule.typeRange, with: type)
                counts[family.id, default: 0] += 1
            }
            lines.insert("# kmap: resolutions set by the zoom plan \"\(plan.name)\""
                         + " — not a source for the hide catalogue", at: 0)
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }

        // Reported per family, and even when the count is zero: a family that matched no
        // rule means the tags have moved, which a silent pass would hide.
        for family in asked {
            let n = counts[family.id] ?? 0
            guard let window = plan.window(family) else { continue }
            if n == 0 {
                log.warn("zoom plan: \(family.nameKey) matched no rule — nothing changed")
            } else {
                log.append("zoom plan: \(family.nameKey) — \(n) rule(s) on rung(s)"
                           + " \(window.rungs.lowerBound)–\(window.rungs.upperBound)")
            }
        }
    }

    /// What to write after `resolution`: a floor, or a floor and a ceiling. `finest == 0`
    /// is no ceiling, which the plain one-number form already expresses.
    private func resolution(from start: Int, to finest: Int, on rungs: ZoomRungs) -> String? {
        guard let floor = rungs.resolution(atRung: start) else { return nil }
        guard finest > 0, let ceiling = rungs.resolution(atRung: finest),
              ceiling != floor else { return "\(floor)" }
        return "\(floor)-\(ceiling)"
    }
}
