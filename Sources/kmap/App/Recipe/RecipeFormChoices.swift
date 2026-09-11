import Foundation

/// The list a field opens: what each row offers, how each option is labelled, and
/// what choosing one writes into the recipe.
extension RecipeForm {
    /// What a field cycles through, where it stands, and what choosing does.
    ///
    /// ←→ steps through `options` from `current`; ⏎ opens them as a list and `choose`
    /// applies the pick. Nil for fields that are not a choice: style, family id, hide,
    /// folder and the button at the end.
    struct Choice {
        let options: [String]
        let current: Int
        /// Whether ⏎ may open the options as a list. False for a row whose value is inert,
        /// such as the interval while contours are off.
        var listable = true
        let choose: (Int) -> Outcome
    }

    func choice(for field: Field, _ ctx: AppContext) -> Choice? {
        /// An on/off row.
        func toggle(_ read: Bool, _ write: @escaping (Bool) -> Void) -> Choice {
            Choice(options: [t("on"), t("off")], current: read ? 0 : 1) { at in
                write(at == 0)
                return .none
            }
        }
        /// A row cycling through values, labelled one way and stored another.
        func among<T: Equatable>(_ values: [T], current: T, label: (T) -> String,
                                 listable: Bool = true,
                                 write: @escaping (T) -> Void) -> Choice {
            Choice(options: values.map(label),
                   current: values.firstIndex(of: current) ?? 0,
                   listable: listable) { at in
                write(values[at])
                return .none
            }
        }

        switch field {
        case .profile:
            return Choice(options: profiles.map(\.name),
                          current: profiles.firstIndex { $0.id == currentProfileID } ?? 0)
            { [self] at in
                use(profiles[at], ctx)
                return .profileChosen(profiles[at].id)
            }
        case .contours: return toggle(recipe.contours) { self.recipe.contours = $0 }
        case .dem: return toggle(recipe.demLayer) { self.recipe.demLayer = $0 }
        case .fixSummits:
            // Inert while there is no DEM to write into, like the interval without contours.
            var choice = toggle(recipe.fixSummits) { self.recipe.fixSummits = $0 }
            choice.listable = recipe.demLayer
            return choice
        case .routable: return toggle(recipe.routable) { self.recipe.routable = $0 }
        case .healRoads: return toggle(recipe.healRoadEnds) { self.recipe.healRoadEnds = $0 }
        case .index: return toggle(recipe.searchIndex) { self.recipe.searchIndex = $0 }
        case .houseNumbers: return toggle(recipe.houseNumbers) { self.recipe.houseNumbers = $0 }
        case .sea: return toggle(recipe.generateSea) { self.recipe.generateSea = $0 }
        case .customPOIs: return toggle(recipe.customPOIs) { self.recipe.customPOIs = $0 }
        case .interval:
            return among(intervals, current: recipe.contourInterval, label: { "\($0) m" },
                         listable: recipe.contours) { self.recipe.contourInterval = $0 }
        case .demSource:
            return among(sourceChoices(ctx), current: recipe.demSources,
                         label: { $0 == BuildRecipe.recommendedDEMSources
                             ? $0 + "  " + t("(recommended)") : $0 },
                         listable: recipe.needsElevationData) { self.recipe.demSources = $0 }
        case .zoomPlan:
            return among(ctx.settings.zoomPlans, current: recipe.zoomPlan,
                         label: RecipeForm.planLabel) { plan in
                // The plan carries the ladder; set together, since a plan's numbers are
                // rungs of its own ladder.
                self.recipe.zoomPlan = plan
                self.recipe.levels = LevelsProfile.all.first { $0.id == plan.levelsID }
                    ?? .smooth
            }
        case .language:
            let current = LabelLanguage.all.first { $0.tagList == recipe.nameTagList } ?? .local
            return among(LabelLanguage.all.map(\.id), current: current.id,
                         label: { id in LabelLanguage.all.first { $0.id == id }?.name ?? id })
            { id in
                self.recipe.nameTagList = LabelLanguage.all.first { $0.id == id }?.tagList ?? ""
            }
        case .codePage:
            return among(codePageChoices, current: recipe.codePage,
                         label: RecipeForm.codePageLabel) { self.recipe.codePage = $0 }
        case .descriptions:
            return among(BuildRecipe.DescriptionCarrier.allCases, current: recipe.descriptions,
                         label: \.label) { self.recipe.descriptions = $0 }
        case .theme:
            return among(TypEdit.Theme.allCases, current: recipe.theme,
                         label: RecipeForm.themeLabel) { self.recipe.theme = $0 }
        case .splitMode:
            let modes: [SplitMode] = [.fitCard, .perRegion, .perCountry,
                                      .count(recipe.splitMode.fileCount > 0
                                             ? recipe.splitMode.fileCount : 2)]
            let at = modes.firstIndex { $0.settingsID == recipe.splitMode.settingsID } ?? 0
            return Choice(options: modes.map(\.label), current: at) { at in
                self.recipe.splitMode = modes[at]
                return .none
            }
        case .parts:
            // Up to 64 files: a continent-sized extract cut to fit a card needs that many.
            guard recipe.splitMode.fileCount > 0 else { return nil }
            return Choice(options: (1...64).map { tn("%d file(s)", $0) },
                          current: max(0, recipe.splitMode.fileCount - 1)) { at in
                self.recipe.splitMode = .count(at + 1)
                return .none
            }
        case .overlap:
            return Choice(options: rungs(upTo: BuildChoices.overlapCeiling),
                          current: recipe.shapeOverlap / BuildChoices.overlapStep) { at in
                self.recipe.shapeOverlap = BuildChoices.sane(at * BuildChoices.overlapStep)
                // Land overlap can never exceed the shape overlap: past it a tile would
                // paint land over ground it holds no cover for.
                self.recipe.landOverlap = min(self.recipe.landOverlap, self.recipe.shapeOverlap)
                return .none
            }
        case .landOverlap:
            // Rungs only as far as the shape overlap reaches.
            return Choice(options: rungs(upTo: recipe.shapeOverlap),
                          current: recipe.landOverlap / BuildChoices.overlapStep) { at in
                self.recipe.landOverlap = min(BuildChoices.sane(at * BuildChoices.overlapStep),
                                              self.recipe.shapeOverlap)
                return .none
            }
        case .style, .familyID, .hide, .output, .build, .save:
            return nil
        }
    }

    private func rungs(upTo ceiling: Int) -> [String] {
        stride(from: 0, through: max(0, ceiling), by: BuildChoices.overlapStep)
            .map(RecipeForm.overlapLabel)
    }


    /// Which of the TYP's two drawings is packed.
    static func themeLabel(_ theme: TypEdit.Theme) -> String {
        switch theme {
        case .all: return t("Day and night")
        case .day: return t("Day only")
        case .night: return t("Night only")
        }
    }

    /// What leaving one of them out is for. Empty for the file as written.
    static func themeHint(_ theme: TypEdit.Theme) -> String {
        switch theme {
        case .all: return ""
        case .day: return t("the day colours at any hour, for a receiver that draws night wrongly")
        case .night: return t("the night colours at any hour")
        }
    }

    /// An overlap in both units: the number that reaches the compiler, and the ground it
    /// covers.
    static func overlapLabel(_ units: Int) -> String {
        guard units > 0 else { return t("off") + "  ·  " + t("a tile stops on its frame") }
        // One map unit is 360/2^24 of a degree; a degree of latitude is about 111 km.
        let metres = Int((Double(units) * 360.0 / 16_777_216.0 * RoadRepair.metresPerDegree).rounded())
        return "\(units)  ·  " + (metres >= 1000
            ? t("about %@ km", String(format: "%.1f", Double(metres) / 1000.0))
            : t("about %d m", metres))
    }
}
