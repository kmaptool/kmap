import Foundation

/// The build choices a style is materialized with. One value travels through the whole
/// materialization instead of four loose parameters.
struct StyleChoices {
    var descriptions: BuildRecipe.DescriptionCarrier = .off
    var hidden: Set<String> = []
    var zoom: (plan: ZoomPlan, levels: LevelsProfile) = (.asMeasured, .smooth)
    var cyrillic = false
}
