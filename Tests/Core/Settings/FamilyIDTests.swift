import XCTest

@testable import kmap

/// Family ids: 8-digit tile ids need 4 digits, and no 2 maps are given 1 id.
final class FamilyIDTests: XCTestCase {
    func testPastTheBandTheIdsGoOnRatherThanRepeat() {
        let store = SettingsStore()
        let band = Dictionary(uniqueKeysWithValues: (6300..<7000).map { ("band/\($0)", $0) })
        store.update { $0.familyIDs.merge(band) { old, _ in old } }
        defer { store.update { settings in for key in band.keys { settings.familyIDs[key] = nil } } }
        let first = store.familyID(for: "past/1")
        let second = store.familyID(for: "past/2")
        defer {
            store.update {
                $0.familyIDs["past/1"] = nil; $0.familyIDs["past/2"] = nil
            }
        }
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(BuildRecipe.familyIDRange.contains(first))
        XCTAssertTrue(BuildRecipe.familyIDRange.contains(second))
    }

    /// 6324 is mkgmap's default family: a map on it shares its tiles with any map another
    /// tool built at mkgmap's defaults, and the 2 hide each other on the device.
    func testMkgmapsDefaultFamilyIsNeverHandedOut() {
        let store = SettingsStore()
        let band = Dictionary(uniqueKeysWithValues: (6300..<6324).map { ("before/\($0)", $0) })
        store.update { $0.familyIDs.merge(band) { old, _ in old } }
        defer { store.update { settings in for key in band.keys { settings.familyIDs[key] = nil } } }
        let next = store.familyID(for: "after-the-band")
        defer { store.update { $0.familyIDs["after-the-band"] = nil } }
        XCTAssertNotEqual(next, 6324)
        XCTAssertTrue(BuildRecipe.reservedFamilyIDs.contains(6324))
    }

    /// A map given 6324 before it was reserved is moved to a free id once, and the build
    /// is told the old one so it can say to remove the old copy.
    func testAStoredReservedIdIsMovedOnce() {
        let store = SettingsStore()
        let key = "stored-6324-\(UUID().uuidString)"
        store.update { $0.familyIDs[key] = 6324 }
        defer { store.update { $0.familyIDs[key] = nil } }
        let moved = store.familyID(for: key)
        XCTAssertNotEqual(moved, 6324)
        XCTAssertEqual(store.movedFamilyID(for: key), 6324)
        XCTAssertEqual(store.familyID(for: key), moved, "and kept from then on")
    }

    /// The note survives a run that never builds: the recipe screen allocates the id and
    /// may be left, and the next run's build still says to remove the old copy.
    func testTheMoveNoteOutlivesTheRun() {
        let key = "noted-6324-\(UUID().uuidString)"
        let first = SettingsStore()
        first.update { $0.familyIDs[key] = 6324 }
        defer {
            first.update {
                $0.familyIDs[key] = nil; $0.movedFamilyIDs[key] = nil
            }
        }
        let moved = first.familyID(for: key)
        let second = SettingsStore()
        XCTAssertEqual(second.familyID(for: key), moved)
        XCTAssertEqual(second.movedFamilyID(for: key), 6324)
    }

    /// A form shows the id a map would get and keeps none: one left without building
    /// takes nothing from the band.
    func testAPreviewSavesNothing() {
        let store = SettingsStore()
        let key = "preview-\(UUID().uuidString)"
        let shown = store.previewFamilyID(for: key)
        XCTAssertNil(SettingsStore().settings.familyIDs[key])
        XCTAssertEqual(store.previewFamilyID(for: key), shown)
    }

    func testAFamilyIdUnder1000IsRefused() async {
        let code = await CLI.run(["build", "region-a", "--family-id=42"])
        XCTAssertEqual(code, 2)
    }
}
