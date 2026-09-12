import XCTest
@testable import kmap

/// What the regions decide: the family-id key and the alphabet.
final class BuildRecipeRegionsTests: RecipeTestCase {

    // MARK: The family id's key

    func testTheIdentityKeyDoesNotDependOnTheOrderTheRegionsWereChosenIn() {
        // The family id is allocated against this: two maps sharing a key share their tile
        // numbers and hide each other on the device.
        let a = region("continent/region-a", "Region A")
        let b = region("continent/region-b", "Region B")
        XCTAssertEqual(BuildRecipe.identityKey([a, b]), BuildRecipe.identityKey([b, a]))
        XCTAssertEqual(BuildRecipe.identityKey([a, b]), "continent/region-a+continent/region-b")
    }

    func testASetIsNotTheSameIdentityAsOneOfItsMembers() {
        let a = region("continent/region-a", "Region A")
        let b = region("continent/region-b", "Region B")
        XCTAssertNotEqual(BuildRecipe.identityKey([a]), BuildRecipe.identityKey([a, b]))
    }

    // MARK: The alphabet

    func testACyrillicCountryIsSuggestedItsOwnCodePage() {
        for id in ["russia", "ukraine", "belarus", "serbia", "mongolia"] {
            XCTAssertEqual(BuildRecipe.suggestedCodePage(for: region(id, id)), 1251, id)
        }
        for id in ["germany", "france", "australia", "japan"] {
            XCTAssertEqual(BuildRecipe.suggestedCodePage(for: region(id, id)), 1252, id)
        }
    }

    func testASubRegionIsJudgedByItsParentRatherThanByItsOwnName() throws {
        // A sub-region's own id says nothing about its alphabet; the parent above it does.
        let data = try JSONSerialization.data(withJSONObject: ["features": [
            ["properties": ["id": "russia", "name": "Russia"]],
            ["properties": ["id": "child-region", "name": "Child Region",
                            "parent": "russia"]],
        ]])
        let index = RegionIndex()
        try index.parse(data)
        let child = try XCTUnwrap(index.region("child-region"))
        XCTAssertEqual(BuildRecipe.suggestedCodePage(for: child, in: index), 1251)
        // Without the index there is nothing to walk.
        XCTAssertEqual(BuildRecipe.suggestedCodePage(for: child), 1252)
    }

    func testTheParentWalkStopsRatherThanFollowingACircle() throws {
        let data = try JSONSerialization.data(withJSONObject: ["features": [
            ["properties": ["id": "top", "name": "Top"]],
            ["properties": ["id": "a", "name": "A", "parent": "top"]],
            ["properties": ["id": "b", "name": "B", "parent": "a"]],
        ]])
        let index = RegionIndex()
        try index.parse(data)
        XCTAssertEqual(BuildRecipe.suggestedCodePage(for: index.region("b")!, in: index), 1252)
    }
}
