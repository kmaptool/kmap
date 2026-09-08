import XCTest
@testable import kmap

/// Managing profiles from the shell: create, change, copy, rename, delete, choose.
final class CLIProfileCommandTests: XCTestCase {

    private var store: SettingsStore!

    override func setUp() {
        super.setUp()
        store = SettingsStore()
        let profiles = store.settings.profiles
        let last = store.settings.lastProfileID
        addTeardownBlock { [store] in
            store?.update { $0.profiles = profiles; $0.lastProfileID = last }
        }
        store.update {
            $0.profiles = [BuildProfile(id: "one", name: "Handheld")]
            $0.lastProfileID = "one"
        }
    }

    private func run(_ arguments: [String]) -> (code: Int32, out: String, error: String) {
        var code: Int32 = 0
        let captured = CLILog.capture {
            code = CLI.profiles(arguments)
        }
        return (code, captured.out, captured.error)
    }

    func testNewCreatesAProfileFromBuildOptions() {
        let made = run(["new", "Watch", "--interval=25", "--no-dem", "--labels=ru"])
        XCTAssertEqual(made.code, 0, made.error)
        let fresh = SettingsStore()
        let watch = try? XCTUnwrap(fresh.profiles.first { $0.name == "Watch" })
        XCTAssertEqual(watch?.choices.contourInterval, 25)
        XCTAssertEqual(watch?.choices.demLayer, false)
        XCTAssertEqual(watch?.choices.labelLanguageID, "ru")
    }

    func testNewRefusesATakenName() {
        XCTAssertEqual(run(["new", "handheld"]).code, 2,
                       "matching is case-insensitive, like --profile")
    }

    func testSetChangesOnlyWhatItIsGiven() {
        _ = run(["set", "Handheld", "--interval=50"])
        let held = SettingsStore().profiles.first { $0.name == "Handheld" }
        XCTAssertEqual(held?.choices.contourInterval, 50)
        XCTAssertEqual(held?.choices.demLayer, BuildChoices().demLayer,
                       "an unnamed field keeps its value")
    }

    func testATypoRefusesTheWholeChange() {
        let refused = run(["set", "Handheld", "--intreval=50"])
        XCTAssertEqual(refused.code, 2)
        XCTAssertTrue(refused.error.contains("--intreval"), refused.error)
        XCTAssertEqual(SettingsStore().profiles.first { $0.name == "Handheld" }?
            .choices.contourInterval, BuildChoices().contourInterval,
                       "nothing may change when anything was refused")
    }

    func testAPerBuildFlagIsRefusedWithAWordToThatEffect() {
        let refused = run(["set", "Handheld", "--out=/tmp/x"])
        XCTAssertEqual(refused.code, 2)
        XCTAssertTrue(refused.error.contains("belongs to one build"), refused.error)
    }

    func testCopyAndRenameAndDelete() {
        XCTAssertEqual(run(["copy", "Handheld", "Bike"]).code, 0)
        XCTAssertEqual(run(["rename", "Bike", "Edge"]).code, 0)
        var fresh = SettingsStore()
        XCTAssertTrue(fresh.profiles.contains { $0.name == "Edge" })
        XCTAssertEqual(run(["delete", "Edge"]).code, 0)
        fresh = SettingsStore()
        XCTAssertFalse(fresh.profiles.contains { $0.name == "Edge" })
    }

    func testTheLastProfileCannotBeDeleted() {
        let refused = run(["delete", "Handheld"])
        XCTAssertEqual(refused.code, 2)
        XCTAssertTrue(refused.error.contains("last profile"), refused.error)
        XCTAssertEqual(SettingsStore().profiles.count, 1)
    }

    func testUseDecidesWhatTheInterfaceOpensOn() {
        _ = run(["new", "Watch"])
        XCTAssertEqual(run(["use", "Watch"]).code, 0)
        XCTAssertEqual(SettingsStore().currentProfile.name, "Watch")
    }

    func testShowAndAnUnknownVerbAndAMissingName() {
        XCTAssertEqual(run(["show", "Handheld"]).code, 0)
        XCTAssertEqual(run(["show", "Nowhere"]).code, 2)
        XCTAssertEqual(run(["frobnicate"]).code, 2)
    }

    func testRenamingToACaseChangeOfItsOwnNameIsAllowed() {
        XCTAssertEqual(run(["rename", "Handheld", "handheld"]).code, 0,
                       "a clash with itself is no clash")
        XCTAssertEqual(SettingsStore().profiles.first?.name, "handheld")
    }

    func testHideValidatesItsIds() {
        let refused = run(["set", "Handheld", "--hide=power-tower,nonsense-id"])
        XCTAssertEqual(refused.code, 2)
        XCTAssertTrue(refused.error.contains("nonsense-id"), refused.error)
        XCTAssertEqual(run(["set", "Handheld", "--hide=power-tower"]).code, 0)
        XCTAssertEqual(SettingsStore().profiles.first { $0.name == "Handheld" }?
            .choices.hiddenFeatures, ["power-tower"])
    }
}
