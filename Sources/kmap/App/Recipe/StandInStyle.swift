import Foundation

extension MapStyle {
    /// The built-in look, standing in until the catalogue answers.
    static var standIn: MapStyle {
        MapStyle(
            id: "plain",
            name: "Plain",
            summary: "",
            origin: .builtin,
            styleDirectory: StyleCatalog.baseStyleDirectory,
            typURL: nil,
            familyID: BuildRecipe.defaultFamilyID,
            productID: 1
        )
    }
}
