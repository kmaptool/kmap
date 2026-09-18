import XCTest
@testable import kmap

/// Zoom plans as the settings keep them: the two that ship cannot be touched, and a name
/// is never held twice.
final class ZoomPlanStoreTests: XCTestCase {

    private func store() -> SettingsStore {
        let store = SettingsStore()
        for plan in store.zoomPlans where !plan.isBuiltin { store.deleteZoomPlan(plan.id) }
        return store
    }

    func testTheShippedPlansComeFirstAndCannotBeChanged() {
        let settings = store()
        XCTAssertEqual(settings.zoomPlans.prefix(2).map(\.id), ZoomPlan.builtins.map(\.id))
        var edited = ZoomPlan.asMeasured
        edited.windows["trails"] = ZoomPlan.Window(finest: 0, coarsest: 1)
        settings.saveZoomPlan(edited)
        XCTAssertEqual(settings.zoomPlan(ZoomPlan.asMeasured.id)?.windows, [:])
        XCTAssertFalse(settings.deleteZoomPlan(ZoomPlan.asMeasured.id))
    }

    func testACopyIsHowAPlanIsMadeAndSavingUpdatesIt() {
        let settings = store()
        var copy = settings.copyZoomPlan(.asMeasured, named: "Hiking")
        XCTAssertFalse(copy.isBuiltin)
        XCTAssertNotEqual(copy.id, ZoomPlan.asMeasured.id)

        copy.windows["trails"] = ZoomPlan.Window(finest: 0, coarsest: 2)
        settings.saveZoomPlan(copy)
        XCTAssertEqual(settings.zoomPlan(copy.id)?.windows["trails"]?.count, 3)
        XCTAssertEqual(settings.zoomPlans.filter { $0.id == copy.id }.count, 1, "updated, not added again")

        let fresh = ZoomPlan(id: "made-elsewhere", name: "Imported", levelsID: LevelsProfile.smooth.id)
        settings.saveZoomPlan(fresh)
        XCTAssertNotNil(settings.zoomPlan("made-elsewhere"))
        XCTAssertTrue(settings.deleteZoomPlan(copy.id))
        XCTAssertNil(settings.zoomPlan(copy.id))
    }

    func testANameIsNeverHeldTwice() {
        let settings = store()
        let first = settings.copyZoomPlan(.asMeasured, named: "Hiking")
        let second = settings.copyZoomPlan(.asMeasured, named: "hiking")
        XCTAssertEqual(first.name, "Hiking")
        XCTAssertEqual(second.name, "hiking 2")
        XCTAssertEqual(settings.uniqueZoomPlanName("  "), "Zoom plan")
        XCTAssertEqual(settings.uniqueZoomPlanName("Hiking", ignoring: first.id), "Hiking",
                       "a plan may keep its own name")
    }

    func testRenamingKeepsNamesUniqueAndIgnoresABlank() {
        let settings = store()
        let first = settings.copyZoomPlan(.asMeasured, named: "Hiking")
        let second = settings.copyZoomPlan(.asMeasured, named: "Cycling")
        settings.renameZoomPlan(second.id, to: "  Hiking ")
        XCTAssertEqual(settings.zoomPlan(second.id)?.name, "Hiking 2")
        settings.renameZoomPlan(second.id, to: "   ")
        XCTAssertEqual(settings.zoomPlan(second.id)?.name, "Hiking 2", "a blank name is not a name")
        settings.renameZoomPlan("no-such-plan", to: "Ghost")
        XCTAssertEqual(settings.zoomPlan(first.id)?.name, "Hiking")
    }

    func testAPlanForAnotherLadderFallsBackToWhatShips() {
        // A window is a pair of indexes into one ladder, and means nothing on the other.
        let settings = store()
        let smooth = settings.copyZoomPlan(.asMeasured, named: "Smooth one")
        XCTAssertEqual(settings.zoomPlan(smooth.id, forLevels: LevelsProfile.smooth.id).id, smooth.id)
        XCTAssertEqual(settings.zoomPlan(smooth.id, forLevels: LevelsProfile.standard.id).id,
                       ZoomPlan.standard.id)
        XCTAssertEqual(settings.zoomPlan("deleted-since", forLevels: LevelsProfile.smooth.id).id,
                       ZoomPlan.asMeasured.id)
        XCTAssertEqual(ZoomPlan.builtin(forLevels: "no-such-ladder").id, ZoomPlan.asMeasured.id)
    }

    func testAPlanFromAnOlderSettingsFileStillLoads() throws {
        // `shifts` and no `windows`, no id: one throw here would lose every plan in the file.
        let old = Data(#"{"name": "Old plan", "shifts": {"trails": 1}}"#.utf8)
        let plan = try JSONDecoder().decode(ZoomPlan.self, from: old)
        XCTAssertEqual(plan.name, "Old plan")
        XCTAssertEqual(plan.levelsID, LevelsProfile.smooth.id)
        XCTAssertFalse(plan.movesAnything, "a shift cannot become a window without the style")
        XCTAssertFalse(plan.id.isEmpty)
    }
}
