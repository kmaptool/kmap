import XCTest

@testable import kmap

/// A small region with nothing fetched yet.
enum PipelineFixture {
    static func pipeline(
        workRoot: URL? = nil,
        regions: Int = 1,
        _ change: (inout BuildRecipe) -> Void = { _ in }
    ) -> BuildPipeline {
        let settings = SettingsStore()
        let toolchain = Toolchain(settings: settings)
        let region = Region(
            id: "continent/small-region",
            name: "Small Region",
            parentID: nil,
            pbfURL: nil,
            bbox: .empty,
            boxes: []
        )
        let style = MapStyle(
            id: "plain",
            name: "Plain",
            summary: "",
            origin: .builtin,
            styleDirectory: nil,
            typURL: nil,
            familyID: 6300,
            productID: 1
        )
        var recipe = BuildRecipe(
            region: region,
            style: style,
            outputDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
        )
        if let workRoot { recipe.workRoot = workRoot }
        recipe.extraRegions = (1..<max(1, regions)).map {
            Region(
                id: "continent/region-\($0)",
                name: "Region \($0)",
                parentID: nil,
                pbfURL: nil,
                bbox: .empty,
                boxes: []
            )
        }
        change(&recipe)
        return BuildPipeline(
            recipe: recipe,
            settings: settings,
            toolchain: toolchain,
            styles: StyleCatalog(settings: settings, toolchain: toolchain)
        )
    }
}
