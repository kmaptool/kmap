import Foundation

/// How the map is drawn and labelled: the level ladder, zoom plan, theme, label language,
/// description carrier and code page. Each from its flag, else from the profile, else
/// the default.
extension CLI {
    struct RenderingChoices {
        let levels: LevelsProfile
        let zoomPlan: ZoomPlan
        let theme: TypEdit.Theme
        let labels: LabelLanguage
        let descriptions: BuildRecipe.DescriptionCarrier
        let codePage: Int

        init(_ asked: inout BuildOptions, choices: BuildChoices, settings: Settings) {
            let ladder =
                asked.word("levels", among: LevelsProfile.all.map { ($0.id, $0) })
                ?? LevelsProfile.all.first { $0.id == choices.levelsID } ?? .smooth
            levels = ladder
            // A plan is stored by id, which is a UUID for a custom plan, and named on the
            // command line. Only plans made for this ladder apply.
            zoomPlan =
                asked.zoomPlan(forLadder: ladder.id, in: settings)
                ?? settings.zoomPlans.first { $0.levelsID == ladder.id && $0.id == choices.zoomPlanID }
                ?? ZoomPlan.builtin(forLevels: ladder.id)
            theme =
                asked.word("theme", among: TypEdit.Theme.allCases.map { ($0.rawValue, $0) })
                ?? TypEdit.Theme(rawValue: choices.theme) ?? .all
            labels =
                asked.word("labels", among: LabelLanguage.all.map { ($0.id, $0) })
                ?? LabelLanguage.all.first { $0.id == choices.labelLanguageID } ?? .local
            descriptions =
                asked.descriptions()
                ?? BuildRecipe.DescriptionCarrier(rawValue: choices.descriptions) ?? .off
            codePage = asked.codePage() ?? choices.codePage
        }
    }
}
