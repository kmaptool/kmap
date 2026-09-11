import XCTest
@testable import kmap

/// The region picker's search: a kept query is a list like any other, so regions found by
/// name can be marked one after another and built together.
@MainActor
final class RegionPickerSearchTests: XCTestCase {

    private func context() throws -> AppContext {
        func feature(_ id: String, _ name: String, parent: String? = nil) -> [String: Any] {
            var properties: [String: Any] = ["id": id, "name": name,
                                             "urls": ["pbf": "https://x/\(id).osm.pbf"]]
            if let parent { properties["parent"] = parent }
            return ["properties": properties]
        }
        let data = try JSONSerialization.data(withJSONObject: ["features": [
            feature("asia", "Asia"),
            feature("asia/nepal", "Nepal", parent: "asia"),
            feature("asia/india", "India", parent: "asia"),
            feature("asia/indonesia", "Indonesia", parent: "asia"),
            feature("europe", "Europe"),
        ]])
        let ctx = AppContext()
        try ctx.index.parse(data)
        // Ready, so nothing goes to fetch the real index.
        ctx.indexState = .ready
        return ctx
    }

    private func type(_ text: String, into screen: Screen, _ ctx: AppContext) {
        for c in text { _ = screen.handle(.char(c), ctx: ctx) }
    }

    private func labels(_ screen: Screen) -> [String] { screen.page.keys.map(\.label) }

    func testAKeptSearchCanBeMarkedAndAnotherSearchedFor() throws {
        let ctx = try context()
        let screen = RegionPickerScreen()

        _ = screen.handle(.char("/"), ctx: ctx)
        type("nep", into: screen, ctx)
        XCTAssertEqual(labels(screen), [t("keep"), t("clear")])
        _ = screen.handle(.enter, ctx: ctx)
        XCTAssertEqual(screen.page.subject, t("search"), "the query stays applied")
        XCTAssertTrue(labels(screen).contains(t("mark several")))

        _ = screen.handle(.char(" "), ctx: ctx)
        XCTAssertTrue(labels(screen).contains(t("build %d", 1)), "Nepal is marked")

        // A new search: the box reopens with the old query, esc clears it.
        _ = screen.handle(.char("/"), ctx: ctx)
        _ = screen.handle(.esc, ctx: ctx)
        _ = screen.handle(.char("/"), ctx: ctx)
        type("ind", into: screen, ctx)
        _ = screen.handle(.enter, ctx: ctx)
        let found = ctx.index.search("ind")
        let india = try XCTUnwrap(found.firstIndex { $0.id == "asia/india" })
        for _ in 0..<india { _ = screen.handle(.down, ctx: ctx) }
        _ = screen.handle(.char(" "), ctx: ctx)
        XCTAssertTrue(labels(screen).contains(t("build %d", 2)), "\(labels(screen))")

        guard case .push(let next) = screen.handle(.enter, ctx: ctx) else {
            return XCTFail("the marked regions did not open a recipe")
        }
        XCTAssertTrue(next is RecipeScreen)
    }

    func testEscapeClearsAKeptQueryBeforeItLeavesTheScreen() throws {
        let ctx = try context()
        let screen = RegionPickerScreen()
        _ = screen.handle(.char("/"), ctx: ctx)
        type("nep", into: screen, ctx)
        _ = screen.handle(.enter, ctx: ctx)
        XCTAssertEqual(screen.page.subject, t("search"))
        guard case .none = screen.handle(.esc, ctx: ctx) else { return XCTFail("left early") }
        XCTAssertNil(screen.page.subject, "the tree is back")
        guard case .pop = screen.handle(.esc, ctx: ctx) else { return XCTFail("did not leave") }
    }

    func testOpeningAFoundRegionDropsTheQuery() throws {
        let ctx = try context()
        let screen = RegionPickerScreen()
        _ = screen.handle(.char("/"), ctx: ctx)
        type("asia", into: screen, ctx)
        _ = screen.handle(.enter, ctx: ctx)
        _ = screen.handle(.right, ctx: ctx)
        XCTAssertNil(screen.page.subject, "inside Asia the list is its children")
    }
}
