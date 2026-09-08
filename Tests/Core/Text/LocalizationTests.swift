import XCTest
@testable import kmap

/// The interface's own language: how it is chosen and how it is looked up.
///
/// `L10n.current` is process-wide by design, so every test here puts the language back
/// where it found it.
final class LocalizationTests: XCTestCase {

    private var before: Lang!

    override func setUp() {
        super.setUp()
        before = L10n.current
    }

    override func tearDown() {
        L10n.use(before)
        super.tearDown()
    }

    // MARK: Which language, and who decides

    func testTheSystemDecidesOnlyWhenNothingIsStored() {
        // A stored choice wins and is not written again; the question is asked once.
        let stored = L10n.resolve(stored: "en", system: ["ru-RU"])
        XCTAssertEqual(stored.language, .en)
        XCTAssertFalse(stored.store)

        let fresh = L10n.resolve(stored: "", system: ["ru-RU", "en-GB"])
        XCTAssertEqual(fresh.language, .ru)
        XCTAssertTrue(fresh.store, "a first run has to write down what it decided")
    }

    func testAStoredLanguageNoBuildUnderstandsFallsBackToTheSystem() {
        // A settings file from a build that offered more languages than this one does.
        let decision = L10n.resolve(stored: "de", system: ["ru-RU"])
        XCTAssertEqual(decision.language, .ru)
        XCTAssertTrue(decision.store)
    }

    func testTheSystemLanguageIsReadPastItsRegionAndPastWhatIsNotOffered() {
        XCTAssertEqual(Lang.fromSystem(["ru-RU"]), .ru)
        XCTAssertEqual(Lang.fromSystem(["ru_RU"]), .ru)
        XCTAssertEqual(Lang.fromSystem(["en"]), .en)
        // Nothing on offer matches, so English rather than nothing.
        XCTAssertEqual(Lang.fromSystem(["fr-FR", "de-DE"]), .en)
        // The first one that is offered wins, not the first one listed.
        XCTAssertEqual(Lang.fromSystem(["fr-FR", "ru-RU", "en-GB"]), .ru)
        XCTAssertEqual(Lang.fromSystem([]), .en)
    }

    func testEveryLanguageNamesItselfInItself() {
        // The names are not translated: each is written in its own language, so it can
        // be found without reading the one on screen.
        XCTAssertEqual(Lang.en.nativeName, "English")
        XCTAssertEqual(Lang.ru.nativeName, "Русский")
    }

    // MARK: Looking a string up

    func testTheTablesAnswerForTheLanguageAskedAndNoOther() {
        XCTAssertEqual(Strings.text("Style", in: .ru), "Стиль")
        // English has no table: its answer is the key itself.
        XCTAssertNil(Strings.text("Style", in: .en))
        XCTAssertNil(Strings.text("a string nobody ever wrote", in: .ru))

        XCTAssertEqual(Strings.plural("%d file(s)", in: .ru)?["few"], "%d файла")
        XCTAssertEqual(Strings.plural("%d file(s)", in: .en)?["other"], "%d files")
        XCTAssertNil(Strings.plural("Style", in: .ru), "a flat string has no plural forms")
    }

    func testAKeyIsItsOwnEnglishText() {
        L10n.use(.en)
        // English needs no entries; an untranslated key reads as English.
        XCTAssertEqual(t("Style"), "Style")
        XCTAssertEqual(t("a string nobody ever put in the catalogue"),
                       "a string nobody ever put in the catalogue")
    }

    func testRussianComesOutOfTheCatalogue() {
        L10n.use(.ru)
        XCTAssertEqual(t("Style"), "Стиль")
        XCTAssertEqual(t("menu"), "меню")
        // Still English where there is no translation, rather than blank.
        XCTAssertEqual(t("a string nobody ever put in the catalogue"),
                       "a string nobody ever put in the catalogue")
    }

    func testValuesAreDroppedIntoTheStringRatherThanAppendedToIt() {
        L10n.use(.en)
        XCTAssertEqual(t("%@ is now the default", "Borrowed"),
                       "Borrowed is now the default")
        // Two of them, in an order the translation is free to change.
        XCTAssertEqual(t("%1$@ exited with code %2$d", "mkgmap", 3),
                       "mkgmap exited with code 3")
    }

    // MARK: Counting

    func testEnglishHasTwoFormsAndRussianFour() {
        XCTAssertEqual(L10n.plural(1, in: .en), "one")
        XCTAssertEqual(L10n.plural(0, in: .en), "other")
        XCTAssertEqual(L10n.plural(2, in: .en), "other")

        // Russian takes four forms, and 21 takes the same one as 1.
        XCTAssertEqual(L10n.plural(1, in: .ru), "one")
        XCTAssertEqual(L10n.plural(21, in: .ru), "one")
        XCTAssertEqual(L10n.plural(101, in: .ru), "one")
        XCTAssertEqual(L10n.plural(2, in: .ru), "few")
        XCTAssertEqual(L10n.plural(24, in: .ru), "few")
        XCTAssertEqual(L10n.plural(5, in: .ru), "many")
        XCTAssertEqual(L10n.plural(0, in: .ru), "many")
        // The teens are the exception both rules trip over.
        XCTAssertEqual(L10n.plural(11, in: .ru), "many")
        XCTAssertEqual(L10n.plural(12, in: .ru), "many")
        XCTAssertEqual(L10n.plural(14, in: .ru), "many")
        XCTAssertEqual(L10n.plural(111, in: .ru), "many")
    }

    func testACountedStringTakesTheFormThatGoesWithItsNumber() {
        L10n.use(.en)
        XCTAssertEqual(tn("%d file(s)", 1), "1 file")
        XCTAssertEqual(tn("%d file(s)", 3), "3 files")

        L10n.use(.ru)
        XCTAssertEqual(tn("%d file(s)", 1), "1 файл")
        XCTAssertEqual(tn("%d file(s)", 3), "3 файла")
        XCTAssertEqual(tn("%d file(s)", 7), "7 файлов")
        XCTAssertEqual(tn("%d file(s)", 21), "21 файл")
    }

    func testACountedStringCanCarrySomethingElseAsWell() {
        L10n.use(.ru)
        XCTAssertEqual(tn("cleared %d file(s), %@", 2, "1.4 GB"),
                       "очищено 2 файла, 1.4 GB")
    }

    func testACountNobodyGaveAPluralFormFallsBackRatherThanBlanks() {
        L10n.use(.ru)
        let out = tn("%d of nothing anybody translated", 5)
        XCTAssertEqual(out, "5 of nothing anybody translated")
    }

    // MARK: Typed values

    func testNoneIsAcceptedInEitherLanguage() {
        // The field shows the word in the language on screen, and "none" is what a TYP
        // file says, so both are accepted.
        L10n.use(.ru)
        XCTAssertTrue(meansNone("none"))
        XCTAssertTrue(meansNone("  NONE "))
        XCTAssertTrue(meansNone("нет"))
        XCTAssertFalse(meansNone("#FF00FF"))

        L10n.use(.en)
        XCTAssertTrue(meansNone("none"))
        XCTAssertFalse(meansNone("#FF00FF"))
    }

    // MARK: Off the main thread

    /// The language is read from background threads while it can be changed on another,
    /// so the value is kept behind a lock. Under the thread sanitiser this exercises it;
    /// without one it still catches a language that comes back as neither.
    func testTheLanguageSurvivesBeingReadWhileItIsBeingChanged() {
        let was = L10n.current
        defer { L10n.use(was) }

        let readers = expectation(description: "readers")
        readers.expectedFulfillmentCount = 8
        for _ in 0..<8 {
            DispatchQueue.global().async {
                for _ in 0..<2_000 {
                    let language = L10n.current
                    XCTAssertTrue(Lang.allCases.contains(language))
                    // Through the whole path a screen uses, not just the property.
                    XCTAssertFalse(t("settings").isEmpty)
                }
                readers.fulfill()
            }
        }
        for i in 0..<200 { L10n.use(i % 2 == 0 ? .en : .ru) }
        wait(for: [readers], timeout: 30)
    }
}
