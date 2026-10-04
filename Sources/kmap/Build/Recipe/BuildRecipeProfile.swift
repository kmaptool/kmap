import Foundation

extension BuildRecipe {
    /// The choices this recipe is carrying, lifted out of it.
    var choices: BuildChoices {
        BuildChoices(
            styleID: style.id,
            contours: contours,
            contourInterval: contourInterval,
            demLayer: demLayer,
            fixSummits: fixSummits,
            demSources: demSources,
            levelsID: levels.id,
            labelLanguageID: LabelLanguage.all
                .first { $0.tagList == nameTagList }?.id ?? LabelLanguage.local.id,
            codePage: codePage,
            routable: routable,
            healRoadEnds: healRoadEnds,
            searchIndex: searchIndex,
            splitNameIndex: splitNameIndex,
            houseNumbers: houseNumbers,
            generateSea: generateSea,
            zoomPlanID: zoomPlan.isBuiltin ? "" : zoomPlan.id,
            descriptions: descriptions.rawValue,
            customPOIs: customPOIs,
            hiddenFeatures: hidden.sorted(),
            splitMode: splitMode.settingsID,
            parts: splitMode.fileCount > 0 ? splitMode.fileCount : 1,
            format: format.rawValue,
            theme: theme.rawValue,
            shapeOverlap: shapeOverlap,
            landOverlap: landOverlap
        )
    }

    /// Lays a set of choices over the recipe, leaving what belongs to this map alone: the
    /// regions, the family id, the output folder and the tile count.
    ///
    /// - Parameters:
    ///   - style: nil while the named style is still being searched for, in which case the
    ///     current style stays.
    ///   - regionCodePage: used when the profile leaves the code page open.
    ///   - plans: the zoom plans to resolve `zoomPlanID` against, passed in so the recipe
    ///     never reads settings itself.
    mutating func apply(
        _ choices: BuildChoices,
        style: MapStyle?,
        regionCodePage: Int,
        plans: [ZoomPlan] = ZoomPlan.builtins
    ) {
        if let style { self.style = style }
        contours = choices.contours
        contourInterval = choices.contourInterval
        demLayer = choices.demLayer
        fixSummits = choices.fixSummits
        demSources = CopernicusDEM.canonicalSourceList(choices.demSources)
        levels = LevelsProfile.all.first { $0.id == choices.levelsID } ?? .smooth
        // A deleted plan, or one made for another ladder, falls back to the built-in.
        zoomPlan =
            plans.first { $0.id == choices.zoomPlanID && $0.levelsID == levels.id }
            ?? ZoomPlan.builtin(forLevels: levels.id)
        nameTagList =
            LabelLanguage.all
            .first { $0.id == choices.labelLanguageID }?.tagList ?? ""
        codePage = choices.codePage != 0 ? choices.codePage : regionCodePage
        routable = choices.routable
        healRoadEnds = choices.healRoadEnds
        searchIndex = choices.searchIndex
        splitNameIndex = choices.splitNameIndex
        houseNumbers = choices.houseNumbers
        generateSea = choices.generateSea
        descriptions = BuildRecipe.DescriptionCarrier(rawValue: choices.descriptions) ?? .off
        customPOIs = choices.customPOIs
        hidden = Set(choices.hiddenFeatures)
        splitMode = SplitMode(settingsID: choices.splitMode, count: choices.parts)
        format = OutputFormat(rawValue: choices.format) ?? .img
        theme = TypEdit.Theme(rawValue: choices.theme) ?? .all
        shapeOverlap = BuildChoices.sane(choices.shapeOverlap)
        landOverlap = min(BuildChoices.sane(choices.landOverlap), shapeOverlap)
    }

    /// Whether the recipe still matches a profile. A code page of 0 counts as the region's
    /// own, and the style is compared by the id asked for, which differs from the id in use
    /// while a borrowed TYP is still being located.
    func matches(_ choices: BuildChoices, regionCodePage: Int, askedStyleID: String) -> Bool {
        var mine = self.choices
        mine.styleID = askedStyleID
        var theirs = choices
        if theirs.codePage == 0 { theirs.codePage = regionCodePage }
        theirs.demSources = CopernicusDEM.canonicalSourceList(theirs.demSources)
        return mine == theirs
    }
}
