import XCTest
@testable import kmap

/// The build screen draws the stages that run beside the others as an indented branch, so
/// a waiting stage in the branch does not read as one the trunk skipped.
final class StageLanesTests: XCTestCase {

    func testOnlyTheElevationPairRunsBeside() {
        let beside = BuildPipeline.StageID.allCases.filter(\.runsBeside)
        XCTAssertEqual(beside, [.elevation, .elevationBuild])
    }

    @MainActor
    func testTheBranchIsDrawnBesideTheTrunk() async {
        let ctx = AppContext()
        let settings = ctx.settings
        let toolchain = Toolchain(settings: settings)
        let region = Region(id: "small-region", name: "Small Region", parentID: nil,
                            pbfURL: nil, bbox: .empty, boxes: [])
        let style = MapStyle(id: "plain", name: "Plain", summary: "", origin: .builtin,
                             styleDirectory: nil, typURL: nil, familyID: 6300, productID: 1)
        let recipe = BuildRecipe(region: region, style: style,
                                 outputDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
        let pipeline = BuildPipeline(recipe: recipe, settings: settings, toolchain: toolchain,
                                     styles: StyleCatalog(settings: settings,
                                                          toolchain: toolchain))
        // The elevation still downloading, its next step waiting, the split already going.
        pipeline.set(.preflight, .done, "ready")
        pipeline.set(.download, .done, "3 extract(s)")
        pipeline.set(.elevation, .running, "76%", fraction: 0.76)
        pipeline.set(.split, .running, "starting")
        let screen = BuildScreen(pipeline: pipeline)
        let surface = Surface()
        surface.resize(110, 40)
        surface.clear(ctx.theme.base)
        screen.tick(ctx)
        screen.render(into: surface, rect: Rect(x: 2, y: 2, w: 106, h: 36), ctx: ctx)
        let rows = surface.asText().split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        let branch = try? XCTUnwrap(rows.first { $0.contains(BuildPipeline.StageID.elevation.title) })
        let trunk = try? XCTUnwrap(rows.first { $0.contains(BuildPipeline.StageID.split.title) })
        guard let branch, let trunk else { return XCTFail("stages were not drawn") }

        // The branch carries a rule in the gutter and starts two columns in; the trunk
        // does neither.
        XCTAssertTrue(branch.contains(String(Glyph.v)), branch)
        XCTAssertFalse(trunk.contains(String(Glyph.v)), trunk)
        let branchAt = branch.distance(from: branch.startIndex,
                                       to: branch.range(of: BuildPipeline.StageID.elevation.title)!.lowerBound)
        let trunkAt = trunk.distance(from: trunk.startIndex,
                                     to: trunk.range(of: BuildPipeline.StageID.split.title)!.lowerBound)
        XCTAssertEqual(branchAt - trunkAt, 2, "the branch should be indented by two")
    }
}
