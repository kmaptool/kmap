import XCTest
@testable import kmap

/// The regions, style and date every recipe test builds from.
class RecipeTestCase: XCTestCase {
    func region(_ id: String, _ name: String, parent: String? = nil,
                box: BBox = .empty) -> Region {
        Region(id: id, name: name, parentID: parent, pbfURL: nil, bbox: box,
               boxes: box.isValid ? [box] : [])
    }

    let style = MapStyle(id: "borrowed", name: "Borrowed", summary: "",
                         origin: .builtin, styleDirectory: nil, typURL: nil,
                         familyID: 6324, productID: 1)

    func recipe(_ regions: [Region]) -> BuildRecipe {
        BuildRecipe(region: regions[0], extraRegions: Array(regions.dropFirst()),
                    style: style, outputDirectory: URL(fileURLWithPath: "/tmp/out"))
    }

    func dated(_ made: BuildRecipe) -> BuildRecipe {
        var out = made
        var parts = DateComponents()
        parts.year = 2026; parts.month = 8; parts.day = 21
        out.startedOn = Calendar(identifier: .gregorian).date(from: parts)!
        return out
    }
}
