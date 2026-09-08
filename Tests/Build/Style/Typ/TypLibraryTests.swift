import XCTest
@testable import kmap

/// Covers importing a third-party TYP into the library.
///
/// Nothing outside the library is written to: a TYP on a mounted drive, or inside a
/// container, is copied first. Every test works in a throwaway folder.
final class TypLibraryTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("typlib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A file with a readable TYP header. Only the identity is real; the body is padding,
    /// which is all `TypInfo` and the importer look at.
    private func makeTyp(named name: String, family: Int, product: Int = 1) throws -> URL {
        var bytes = [UInt8](repeating: 0, count: 0x60)
        bytes[0] = 0x5B                                     // header length, low byte
        for (i, b) in Array("GARMIN TYP".utf8).enumerated() { bytes[2 + i] = b }
        bytes[0x2F] = UInt8(family & 0xFF)
        bytes[0x30] = UInt8((family >> 8) & 0xFF)
        bytes[0x31] = UInt8(product & 0xFF)
        bytes[0x32] = UInt8((product >> 8) & 0xFF)
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private func library() -> URL { folder.appendingPathComponent("library", isDirectory: true) }

    // MARK: Copying

    // MARK: Looking around the machine

    /// Runs the import scan against whatever this machine holds. Asserts only the shape of
    /// each result; finding nothing is a valid answer.
    func testTheScanSurvivesWhateverIsOnThisMachine() {
        let found = TypLibrary.discover(excluding: nil)
        for candidate in found {
            XCTAssertGreaterThan(candidate.familyID, 0, candidate.url.nativePath)
            XCTAssertFalse(candidate.name.isEmpty, candidate.url.nativePath)
        }
    }

    func testTheRootsAreDirectoriesThatExistAndNothingElse() {
        // Mount points per platform, each appended with "Garmin" and tested for existence.
        for root in TypLibrary.searchRoots() {
            XCTAssertTrue(FileTools.exists(root), root.nativePath)
            XCTAssertEqual(root.lastPathComponent, "Garmin")
        }
    }

    func testACompiledTypIsDecompiledOnTheWayIn() throws {
        let source = try makeTyp(named: "borrowed.typ", family: 1535)
        let before = try Data(contentsOf: source)

        let result = try TypLibrary.take(at: source, into: library())

        XCTAssertTrue(result.decompiled)
        XCTAssertEqual(result.url.pathExtension, "txt")
        XCTAssertEqual(result.url.deletingLastPathComponent().standardizedFileURL,
                       library().standardizedFileURL)
        XCTAssertEqual(TypSource.read(result.url)?.familyID, 1535)
        XCTAssertEqual(try Data(contentsOf: source), before, "the original must be untouched")
    }

    /// The binary is kept beside the source it produced, since the source is a
    /// reconstruction and the original still builds where the decoder refused an element.
    func testTheOriginalBinaryIsKeptButNotListedAsASecondStyle() throws {
        let result = try TypLibrary.take(at: try makeTyp(named: "borrowed.typ", family: 1535),
                                         into: library())
        let kept = try XCTUnwrap(result.original)
        XCTAssertTrue(FileTools.exists(kept))
        XCTAssertEqual(kept.pathExtension, "typ")

        // One import, one style: the originals folder is a subfolder, and listing skips it.
        XCTAssertEqual(TypLibrary.contents(in: library()).map(\.lastPathComponent),
                       [result.url.lastPathComponent])
    }

    /// A TYP source is copied verbatim: nothing to decompile, no original to keep.
    func testATypSourceIsCopiedAsItIs() throws {
        let text = "; a hand-written TYP\n[_id]\nFID=6324\nProductCode=1\nCodePage=1252\n[end]\n"
        let file = folder.appendingPathComponent("mine.txt")
        try Data(text.utf8).write(to: file)

        let result = try TypLibrary.take(at: file, into: library())
        XCTAssertFalse(result.decompiled)
        XCTAssertNil(result.original)
        XCTAssertEqual(try String(contentsOf: result.url, encoding: .utf8), text,
                       "including the comment, which is the whole reason source is source")
    }

    func testTheFamilyIdIsPutInTheNameSoTwoBorrowedLooksAreTellableApart() throws {
        let landed = try TypLibrary.take(at: try makeTyp(named: "style.typ", family: 1535),
                                         into: library()).url
        XCTAssertTrue(landed.lastPathComponent.contains("1535"), landed.lastPathComponent)
    }

    func testANameThatAlreadyCarriesItsFamilyIdIsNotGivenASecondOne() throws {
        let landed = try TypLibrary.take(at: try makeTyp(named: "style-1535.typ", family: 1535),
                                         into: library()).url
        XCTAssertEqual(landed.lastPathComponent, "style-1535.txt")
    }

    /// A file already in the library may carry edits, so re-importing its original must
    /// not overwrite it.
    func testImportingTwiceKeepsBothRatherThanOverwritingTheFirst() throws {
        let source = try makeTyp(named: "borrowed.typ", family: 1535)
        let first = try TypLibrary.take(at: source, into: library()).url

        // Stands in for an edit made after importing.
        try Data("edited by hand".utf8).write(to: first)

        let second = try TypLibrary.take(at: source, into: library()).url

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "edited by hand",
                       "the edited copy must survive a re-import of its original")
        XCTAssertEqual(TypLibrary.contents(in: library()).count, 2)
    }

    // MARK: What comes back out

    func testTheLibraryListsTypsAndSourcesAndNothingElse() throws {
        let library = self.library()
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        for name in ["a.typ", "b.txt", "notes.md", "map.img"] {
            try Data("x".utf8).write(to: library.appendingPathComponent(name))
        }
        XCTAssertEqual(TypLibrary.contents(in: library).map(\.lastPathComponent),
                       ["a.typ", "b.txt"])
    }

    func testAMissingLibraryIsEmptyRatherThanAnError() {
        XCTAssertEqual(TypLibrary.contents(in: folder.appendingPathComponent("nope")), [])
    }

    // MARK: Refusing what is not a TYP

    func testAFileThatIsNeitherTypNorImgIsRefused() throws {
        let rubbish = folder.appendingPathComponent("notes.md")
        try Data("hello".utf8).write(to: rubbish)
        XCTAssertThrowsError(try TypLibrary.take(at: rubbish, into: library())) { error in
            XCTAssertTrue("\(error)".contains("notATyp") || error.localizedDescription.contains("neither"),
                          "\(error)")
        }
    }

    func testAPathThatIsNotThereSaysSoRatherThanFailingSilently() {
        let missing = folder.appendingPathComponent("ghost.typ")
        XCTAssertThrowsError(try TypLibrary.take(at: missing, into: library()))
        XCTAssertEqual(TypLibrary.contents(in: library()), [])
    }

    // MARK: Writing, and refusing to

    func testEditedSourceIsWrittenBackOverTheLibraryFile() throws {
        let library = self.library()
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let file = library.appendingPathComponent("mine.txt")
        try Data("[_id]\nFID=1\n[end]".utf8).write(to: file)

        try TypLibrary.save("[_id]\nFID=2\n[end]", to: file, library: library)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "[_id]\nFID=2\n[end]")
    }

    func testWritingOutsideTheLibraryIsRefusedAndNothingIsCreated() {
        let stranger = folder.appendingPathComponent("somebody-elses.typ")
        XCTAssertThrowsError(try TypLibrary.save("x", to: stranger, library: library()))
        XCTAssertFalse(FileTools.exists(stranger))
    }

    /// The materialized style directory is rebuilt from mkgmap on every version change, so
    /// anything written there is undone.
    func testTheMaterializedStyleDirectoryIsNotSomewhereKmapWrites() {
        XCTAssertFalse(TypLibrary.mayWrite(to: Paths.styles
            .appendingPathComponent("something.typ.txt")))
        XCTAssertFalse(TypLibrary.mayWrite(to: StyleCatalog.baseStyleDirectory
            .appendingPathComponent("points")))
    }

    func testALibraryFileIsSomewhereKmapWrites() {
        XCTAssertTrue(TypLibrary.mayWrite(to: TypLibrary.directory
            .appendingPathComponent("borrowed.typ")))
    }

    /// A subfolder is not the library: a path that merely starts with the library's path
    /// must be refused.
    func testASubfolderOfTheLibraryIsNotTheLibrary() {
        XCTAssertFalse(TypLibrary.mayWrite(to: TypLibrary.legacyExtractedDirectory
            .appendingPathComponent("x.typ")))
    }

    // MARK: Adopting a style that cannot be edited where it lies

    func testAdoptingWritesAnEditableSourceIntoTheLibrary() throws {
        let landed = try TypLibrary.adopt(source: "[_id]\nFID=6324\n[end]",
                                          named: "Sample Style (mine)", into: library())
        XCTAssertEqual(landed.pathExtension, "txt")
        XCTAssertTrue(TypLibrary.mayWrite(to: landed, library: library()))
        XCTAssertEqual(try String(contentsOf: landed, encoding: .utf8), "[_id]\nFID=6324\n[end]")
    }

    func testAdoptingTwiceKeepsBoth() throws {
        let first = try TypLibrary.adopt(source: "a", named: "sample-style", into: library())
        let second = try TypLibrary.adopt(source: "b", named: "sample-style", into: library())
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "a")
    }

    // MARK: Managing what is in it

    func testDeletingTakesTheFileAndTheOriginalKeptBesideIt() throws {
        let result = try TypLibrary.take(at: try makeTyp(named: "borrowed.typ", family: 1535),
                                         into: library())
        let original = try XCTUnwrap(result.original)
        XCTAssertTrue(FileTools.exists(original))

        try TypLibrary.delete(result.url, library: library())

        XCTAssertFalse(FileTools.exists(result.url))
        XCTAssertFalse(FileTools.exists(original),
                       "the kept binary serves only that file and is orphaned without it")
        XCTAssertEqual(TypLibrary.contents(in: library()), [])
    }

    /// A delete goes through the same guard as a write.
    func testDeletingSomethingOutsideTheLibraryIsRefused() throws {
        let stranger = try makeTyp(named: "theirs.typ", family: 1)
        XCTAssertThrowsError(try TypLibrary.delete(stranger, library: library()))
        XCTAssertTrue(FileTools.exists(stranger))
    }

    func testRenamingKeepsTheContentsAndTheExtension() throws {
        let landed = try TypLibrary.take(at: try makeTyp(named: "borrowed.typ", family: 1535),
                                         into: library()).url
        let before = try String(contentsOf: landed, encoding: .utf8)

        let moved = try TypLibrary.rename(landed, to: "My Winter Look", library: library())

        XCTAssertEqual(moved.pathExtension, landed.pathExtension)
        XCTAssertTrue(moved.lastPathComponent.contains("winter"), moved.lastPathComponent)
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), before)
        XCTAssertFalse(FileTools.exists(landed))
    }

    /// The kept binary follows its source, so a later delete still finds the pair.
    func testRenamingBringsTheKeptOriginalWithIt() throws {
        let result = try TypLibrary.take(at: try makeTyp(named: "borrowed.typ", family: 1535),
                                         into: library())
        let moved = try TypLibrary.rename(result.url, to: "renamed", library: library())
        let expected = TypLibrary.originalsDirectory(in: library())
            .appendingPathComponent(moved.deletingPathExtension().lastPathComponent + ".typ")
        XCTAssertTrue(FileTools.exists(expected))
        XCTAssertFalse(FileTools.exists(try XCTUnwrap(result.original)))
    }

    func testRenamingOntoATakenNameDoesNotOverwriteIt() throws {
        let first = try TypLibrary.create(named: "alpha", into: library())
        let second = try TypLibrary.create(named: "beta", into: library())
        let moved = try TypLibrary.rename(second, to: "alpha", library: library())
        XCTAssertNotEqual(moved, first)
        XCTAssertTrue(FileTools.exists(first))
        XCTAssertEqual(TypLibrary.contents(in: library()).count, 2)
    }

    func testRenamingToNothingIsRefused() throws {
        let url = try TypLibrary.create(named: "alpha", into: library())
        XCTAssertThrowsError(try TypLibrary.rename(url, to: "   ", library: library()))
        XCTAssertTrue(FileTools.exists(url))
    }

    // MARK: Starting from nothing

    /// A new style carries no sections: a type with no section is left to the receiver.
    func testANewStyleIsValidAndEmpty() throws {
        let url = try TypLibrary.create(named: "From Scratch", familyID: 4242,
                                        into: library())
        let source = try XCTUnwrap(TypSource.read(url))

        XCTAssertEqual(source.familyID, 4242)
        XCTAssertEqual(source.sections.count, 0)
        XCTAssertTrue(TypLibrary.mayWrite(to: url, library: library()))
        XCTAssertEqual(url.pathExtension, "txt")
    }

    /// A draw-order block is present from the start: a polygon added later is not drawn
    /// without an entry in one.
    func testANewStyleHasSomewhereToPutADrawOrderEntry() throws {
        let url = try TypLibrary.create(named: "scratch", into: library())
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("[_drawOrder]"), text)
    }

    func testTwoNewStylesWithTheSameNameBothSurvive() throws {
        let first = try TypLibrary.create(named: "mine", into: library())
        let second = try TypLibrary.create(named: "mine", into: library())
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(TypLibrary.contents(in: library()).count, 2)
    }

    // MARK: Where it looks

    /// The library is the destination, never a source: as a search root it would offer
    /// every file in it back for importing into itself.
    func testTheLibraryIsNotOneOfThePlacesSearchedForImports() {
        let roots = TypLibrary.searchRoots().map(\.standardizedFileURL.path)
        XCTAssertFalse(roots.contains(TypLibrary.directory.standardizedFileURL.path))
    }

    // MARK: What was taken, and when

    func testAnImportIsWrittenDownWithWhereItCameFrom() throws {
        let library = self.library()
        let source = folder.appendingPathComponent("borrowed.typ")
        let landed = library.appendingPathComponent("borrowed-1550.txt")

        TypLibrary.recordImport(from: source, to: landed,
                                at: Date(timeIntervalSince1970: 1_700_000_000),
                                fingerprint: 0xDEAD_BEEF_0000_0001,
                                note: "rights confirmed by the user", in: library)
        TypLibrary.recordImport(from: source, to: landed,
                                at: Date(timeIntervalSince1970: 1_700_003_600),
                                note: "rights confirmed by the user", in: library)

        let log = try String(contentsOf: TypLibrary.importLog(in: library), encoding: .utf8)
        let lines = log.split(separator: "\n")
        XCTAssertEqual(lines.count, 2, "each import adds a line rather than replacing one")
        XCTAssertTrue(lines[0].contains(source.path), "where it came from")
        XCTAssertTrue(lines[0].contains("borrowed-1550.txt"), "and what it became")
        XCTAssertTrue(lines[0].contains("rights confirmed"))
        XCTAssertTrue(lines[0].contains("2023-11-14"), "and when it was agreed to")
        XCTAssertTrue(lines[0].contains("deadbeef00000001"),
                      "and which file it was, once the drive that path names is gone")
    }

    func testTheLogIsNotAStyle() {
        // The log lives in the library folder, which is listed as styles.
        XCTAssertFalse(["typ", "txt"].contains(
            TypLibrary.importLog().pathExtension.lowercased()))
    }

    // MARK: Telling one TYP from another

    /// A family id is not an identity: one product ships several TYPs under one family.
    func testTwoTypsOfTheSameFamilyAreNotTheSameFile() throws {
        let one = try makeTyp(named: "style_1.typ", family: 1540)
        let two = try makeTyp(named: "style_2.typ", family: 1540)
        // Same identity, different bytes.
        var bytes = try Data(contentsOf: two)
        bytes[0x50] = 0x7F
        try bytes.write(to: two)

        XCTAssertNotEqual(TypLibrary.fingerprint(ofTypAt: one),
                          TypLibrary.fingerprint(ofTypAt: two))
    }

    func testTheSameBytesFingerprintTheSameWhateverTheyAreCalled() throws {
        let original = try makeTyp(named: "product.typ", family: 1550)
        let copy = folder.appendingPathComponent("renamed.typ")
        try FileManager.default.copyItem(at: original, to: copy)
        XCTAssertEqual(TypLibrary.fingerprint(ofTypAt: original),
                       TypLibrary.fingerprint(ofTypAt: copy))
        XCTAssertNotEqual(TypLibrary.fingerprint(ofTypAt: original), 0)
    }

    func testWhatIsHeldIsAnsweredByTheBytesFirstAndTheFamilySecond() throws {
        let library = self.library()
        let taken = try makeTyp(named: "taken.typ", family: 1540, product: 1)
        try TypLibrary.take(at: taken, into: library)

        let held = TypLibrary.held(in: library)

        // The file that was imported: held exactly, and the library entry is named.
        let same = TypCandidate(url: taken, isEmbedded: false, familyID: 1540, productID: 1,
                                size: 0, name: "taken", location: "somewhere",
                                fingerprint: TypLibrary.fingerprint(ofTypAt: taken))
        guard case .exact(let name) = TypLibrary.holding(of: same, in: held) else {
            return XCTFail("the file that was imported is not recognised as held")
        }
        XCTAssertTrue(name.contains("taken"))

        // Another TYP of the same product: the weaker claim only.
        let sibling = try makeTyp(named: "sibling.typ", family: 1540, product: 1)
        var bytes = try Data(contentsOf: sibling)
        bytes[0x50] = 0x11
        try bytes.write(to: sibling)
        let other = TypCandidate(url: sibling, isEmbedded: false, familyID: 1540, productID: 1,
                                 size: 0, name: "sibling", location: "somewhere",
                                 fingerprint: TypLibrary.fingerprint(ofTypAt: sibling))
        XCTAssertEqual(TypLibrary.holding(of: other, in: held), .family)

        // Something else entirely.
        let stranger = TypCandidate(url: taken, isEmbedded: false, familyID: 9999, productID: 1,
                                    size: 0, name: "stranger", location: "elsewhere",
                                    fingerprint: 12345)
        XCTAssertEqual(TypLibrary.holding(of: stranger, in: held), .none)
    }

    func testACandidateNothingCouldBeReadFromFallsBackToItsFamily() throws {
        let library = self.library()
        let taken = try makeTyp(named: "taken.typ", family: 1560, product: 2)
        try TypLibrary.take(at: taken, into: library)

        let unreadable = TypCandidate(url: taken, isEmbedded: false, familyID: 1560,
                                      productID: 2, size: 0, name: "?", location: "?",
                                      fingerprint: 0)
        XCTAssertEqual(TypLibrary.holding(of: unreadable, in: TypLibrary.held(in: library)),
                       .family, "a fingerprint of zero must not match anything exactly")
    }

    // MARK: A second copy of the same product

    /// A second import of the same file lands beside the first under a dated name, since
    /// the copy already in the library may carry edits.
    func testASecondImportIsDatedRatherThanNumbered() throws {
        let library = self.library()
        let source = try makeTyp(named: "sample_style.typ", family: 3332)
        let day = Date(timeIntervalSince1970: 1_756_000_000)   // 2025-08-24

        let first = try TypLibrary.take(at: source, into: library, on: day)
        let second = try TypLibrary.take(at: source, into: library, on: day)

        XCTAssertEqual(first.url.lastPathComponent, "sample_style-3332.txt")
        XCTAssertTrue(second.url.lastPathComponent.contains("2025-08-24"),
                      "got \(second.url.lastPathComponent)")
        XCTAssertNotEqual(first.url, second.url, "and nothing was written over")
        XCTAssertTrue(FileTools.exists(first.url), "the edited copy is still there")
    }

    func testTwoImportsOnOneDayStillGetSeparateNames() throws {
        let library = self.library()
        let source = try makeTyp(named: "sample_style.typ", family: 3332)
        let day = Date(timeIntervalSince1970: 1_756_000_000)

        let all = try (0..<3).map { _ in try TypLibrary.take(at: source, into: library, on: day) }
        XCTAssertEqual(Set(all.map(\.url)).count, 3, "a name still has to be free")
        XCTAssertTrue(all[2].url.lastPathComponent.contains("2025-08-24"))
    }

    func testTheKeptOriginalFollowsTheDatedName() throws {
        let library = self.library()
        let source = try makeTyp(named: "sample_style.typ", family: 3332)
        let day = Date(timeIntervalSince1970: 1_756_000_000)

        _ = try TypLibrary.take(at: source, into: library, on: day)
        let second = try TypLibrary.take(at: source, into: library, on: day)

        // The kept binary is named after its entry, which is how a held file is found.
        guard let original = second.original else {
            return XCTFail("a compiled import keeps its original")
        }
        XCTAssertEqual(original.deletingPathExtension().lastPathComponent,
                       second.url.deletingPathExtension().lastPathComponent)
    }

    func testAnImportReportsTheFingerprintOfWhatItTook() throws {
        let library = self.library()
        let source = try makeTyp(named: "product.typ", family: 1550)
        let taken = try TypLibrary.take(at: source, into: library)
        XCTAssertEqual(taken.fingerprint, TypLibrary.fingerprint(ofTypAt: source))
        XCTAssertNotEqual(taken.fingerprint, 0)
    }

    // MARK: Copying and going back

    func testADuplicateIsADatedCopyWithItsOriginalBeside() throws {
        let library = self.library()
        let source = try makeTyp(named: "sample.typ", family: 3332)
        let taken = try TypLibrary.take(at: source, into: library)
        try "edited by hand".write(to: taken.url, atomically: true, encoding: .utf8)

        let day = Date(timeIntervalSince1970: 1_756_000_000)     // 2025-08-24
        let copy = try TypLibrary.duplicate(taken.url, library: library, on: day)

        XCTAssertNotEqual(copy, taken.url)
        XCTAssertTrue(copy.lastPathComponent.contains("2025-08-24"), copy.lastPathComponent)
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "edited by hand",
                       "a copy is of what is there, edits and all")
        // A copy needs an original of its own to be restorable.
        XCTAssertNotNil(TypLibrary.original(of: copy, library: library))
    }

    func testRestoringRewritesTheEntryFromTheBinaryKeptAtImport() throws {
        let library = self.library()
        let source = try makeTyp(named: "sample.typ", family: 3332)
        let taken = try TypLibrary.take(at: source, into: library)
        let asImported = try String(contentsOf: taken.url, encoding: .utf8)

        try "ruined".write(to: taken.url, atomically: true, encoding: .utf8)
        try TypLibrary.restore(taken.url, library: library)

        // Everything but the header, which names the file it was decompiled from: the
        // source file at import, the kept copy here.
        func body(_ text: String) -> [String] {
            Array(text.split(separator: "\n", omittingEmptySubsequences: false)
                    .drop { $0.hasPrefix(";") || $0.isEmpty }
                    .map(String.init))
        }
        XCTAssertEqual(body(try String(contentsOf: taken.url, encoding: .utf8)),
                       body(asImported))
        XCTAssertNotNil(TypLibrary.original(of: taken.url, library: library),
                        "the kept original survives, so this can be done again")
    }

    func testRestoringSaysSoWhenThereIsNothingToGoBackTo() throws {
        let library = self.library()
        let made = try TypLibrary.create(named: "from scratch", into: library)
        XCTAssertNil(TypLibrary.original(of: made, library: library))
        XCTAssertThrowsError(try TypLibrary.restore(made, library: library))
    }

    func testNeitherWillTouchAFileOutsideTheLibrary() throws {
        let outside = try makeTyp(named: "somebody-elses.typ", family: 1)
        XCTAssertThrowsError(try TypLibrary.duplicate(outside, library: library()))
        XCTAssertThrowsError(try TypLibrary.restore(outside, library: library()))
        XCTAssertTrue(FileTools.exists(outside), "and it is still there")
    }

    // MARK: The map a style came out of

    /// A Garmin container by its signature only: `DSKIMG` at 0x10 is all `isImg` reads.
    private func makeImg(named name: String) throws -> URL {
        var bytes = [UInt8](repeating: 0, count: 0x40)
        for (i, b) in Array("DSKIMG".utf8).enumerated() { bytes[0x10 + i] = b }
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    /// The import log is what remembers which map a TYP was taken from.
    func testTheMapAStyleWasTakenFromIsReadBackFromTheLog() throws {
        let img = try makeImg(named: "source-map.img")
        let entry = folder.appendingPathComponent("source-map-1520.txt")
        TypLibrary.recordImport(from: img, to: entry, fingerprint: 0xabc,
                                note: "rights confirmed", in: folder)
        XCTAssertEqual(TypLibrary.importedSource(of: entry, library: folder), img)
    }

    /// Log lines exist in two shapes, with and without the fingerprint column; both answer.
    func testTheOlderLogShapeWithoutAFingerprintStillAnswers() throws {
        let img = try makeImg(named: "old.img")
        let entry = folder.appendingPathComponent("old-style.txt")
        try "2026-08-24T13:07:20Z\told-style.txt\t\(img.path)\trights confirmed by the user\n"
            .write(to: TypLibrary.importLog(in: folder), atomically: true, encoding: .utf8)
        XCTAssertEqual(TypLibrary.importedSource(of: entry, library: folder), img)
    }

    func testAMapThatIsGoneOrNotAMapOffersNothing() throws {
        let entry = folder.appendingPathComponent("gone.txt")
        let unplugged = folder.appendingPathComponent("unplugged.img")
        TypLibrary.recordImport(from: unplugged, to: entry, note: "rights", in: folder)
        XCTAssertNil(TypLibrary.importedSource(of: entry, library: folder),
                     "the drive it named is not there")

        // A TYP taken on its own: the source is a .typ, so there is no map to read.
        let lone = try makeTyp(named: "lone.typ", family: 1)
        let loneEntry = folder.appendingPathComponent("lone-1.txt")
        TypLibrary.recordImport(from: lone, to: loneEntry, note: "rights", in: folder)
        XCTAssertNil(TypLibrary.importedSource(of: loneEntry, library: folder))
    }

    func testTheLatestImportOfAnEntryWins() throws {
        let first = try makeImg(named: "first.img")
        let second = try makeImg(named: "second.img")
        let entry = folder.appendingPathComponent("twice.txt")
        TypLibrary.recordImport(from: first, to: entry, note: "rights", in: folder)
        TypLibrary.recordImport(from: second, to: entry, note: "rights", in: folder)
        XCTAssertEqual(TypLibrary.importedSource(of: entry, library: folder), second)
    }
}
