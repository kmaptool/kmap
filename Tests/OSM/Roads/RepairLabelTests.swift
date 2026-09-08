import XCTest
@testable import kmap

/// The name a repaired link carries: what it crosses, its height where OSM gives one, and
/// how far it reaches, in both alphabets.
final class RepairLabelTests: XCTestCase {

    func testTheSignNamesWhatIsCrossedAndHowFar() {
        XCTAssertEqual(RepairLabel.sign("kerb", 1.5, .nan, "en"), "Kerb, 1.50 m")
        XCTAssertEqual(RepairLabel.sign("kerb", 1.5, .nan, "ru"), "Бордюр, 1.50 м")
    }

    func testAHeightIsAddedWhenOSMKnowsOne() {
        XCTAssertEqual(RepairLabel.sign("retaining_wall", 2, 1.2, "en"),
                       "Retaining wall 1.2 m high, 2.00 m")
        XCTAssertEqual(RepairLabel.sign("retaining_wall", 2, 1.2, "ru"),
                       "Подпорная стенка высотой 1.2 м, 2.00 м")
    }

    func testNoHeightMeansNoHeightInTheName() {
        XCTAssertFalse(RepairLabel.sign("fence", 1, .nan, "en").contains("high"))
        XCTAssertFalse(RepairLabel.sign("fence", 1, .nan, "ru").contains("высотой"))
    }

    func testAWordTheTableDoesNotHaveFallsBackToSomethingSayable() {
        // An unlisted barrier value falls back to a generic word.
        XCTAssertEqual(RepairLabel.sign("something_new", 1, .nan, "en"), "Obstacle, 1.00 m")
        XCTAssertEqual(RepairLabel.sign("something_new", 1, .nan, "ru"), "Преграда, 1.00 м")
    }

    func testAnUnknownLanguageReadsInEnglish() {
        XCTAssertEqual(RepairLabel.sign("kerb", 1, .nan, "de"), "Kerb, 1.00 m")
    }

    func testTheLinkRepeatsTheSignSoEitherOneReadsTheSame() {
        // The link and the mark halfway along it carry the same wording.
        let link = RepairLabel.link("kerb", 1.5, .nan, "en")
        XCTAssertEqual(link, "Repaired link (kerb, 1.50 m)")
        XCTAssertTrue(link.contains("1.50 m"))
    }

    func testTheLinkLowercasesTheFirstLetterInCyrillicToo() {
        // Only the word inside the brackets is lowercased, not the sentence.
        XCTAssertEqual(RepairLabel.link("kerb", 1.5, .nan, "ru"),
                       "Перемычка (достроена, бордюр, 1.50 м)")
    }

    func testTheGroundsOwnReasonsAreNamedToo() {
        // Reasons taken from the DEM rather than from a tag.
        XCTAssertEqual(RepairLabel.sign("drop", 3, .nan, "en"), "Drop in the ground, 3.00 m")
        XCTAssertEqual(RepairLabel.sign("face", 3, .nan, "ru"), "Крутой склон, 3.00 м")
        XCTAssertEqual(RepairLabel.sign("ravine", 3, .nan, "ru"), "Овраг, 3.00 м")
    }

    func testEveryWordInOneAlphabetHasItsPairInTheOther() {
        // A missing translation shows up as the generic fallback word.
        let english = RepairLabel.sign("kerb", 1, .nan, "en")
        let russian = RepairLabel.sign("kerb", 1, .nan, "ru")
        XCTAssertNotEqual(english, russian)
        for word in ["kerb", "retaining_wall", "guard_rail", "ditch", "chain", "bollard",
                     "block", "handrail", "jersey_barrier", "gate", "cliff", "ravine",
                     "water", "river", "canal", "embankment", "pier", "breakwater",
                     "drop", "face"] {
            let ru = RepairLabel.sign(word, 1, .nan, "ru")
            XCTAssertFalse(ru.hasPrefix("Преграда"), "\(word) has no Russian word")
            let en = RepairLabel.sign(word, 1, .nan, "en")
            XCTAssertFalse(en.hasPrefix("Obstacle"), "\(word) has no English word")
        }
    }

    func testTheDistanceIsAlwaysTwoDecimalsSoTheNamesLineUp() {
        XCTAssertTrue(RepairLabel.sign("kerb", 0.5, .nan, "en").hasSuffix("0.50 m"))
        XCTAssertTrue(RepairLabel.sign("kerb", 10, .nan, "en").hasSuffix("10.00 m"))
    }
}
