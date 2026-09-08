import XCTest
@testable import kmap

/// Unpacking a zip with whatever the machine has for the job. The two tools do the same
/// three things with different letters, and a wrong order or a missing `-O` turns "read
/// one entry" into "write a file into the working directory".
final class ArchiveTests: XCTestCase {

    private let unzip = Archive(tool: .unzip, path: "/usr/bin/unzip")
    private let bsdtar = Archive(tool: .bsdtar, path: #"C:\Windows\System32\tar.exe"#)
    private let jar = URL(fileURLWithPath: "/home/k/.kmap/tools/mkgmap/mkgmap.jar")

    // MARK: Which one this machine has

    func testTheUnixesUseUnzipAndAreToldWhereItActuallyIs() {
        // Found rather than assumed: /usr/bin/unzip is absent from a slim base image.
        let found = Archive.found(on: .linux, which: { $0 == "unzip" ? "/opt/bin/unzip" : nil })
        XCTAssertEqual(found, Archive(tool: .unzip, path: "/opt/bin/unzip"))
    }

    func testWindowsUsesTheTarItShipsWithBecauseItHasNeverHadUnzip() {
        let found = Archive.found(on: .windows, which: { $0 == "tar" ? #"C:\Windows\System32\tar.exe"# : nil })
        XCTAssertEqual(found?.tool, .bsdtar)
        XCTAssertEqual(found?.name, "tar")
    }

    func testLinuxIsNeverGivenGnuTarBecauseItCannotReadAZipAtAll() {
        // `tar` on Linux is GNU tar, which cannot read a zip at all.
        XCTAssertNil(Archive.found(on: .linux, which: { $0 == "tar" ? "/usr/bin/tar" : nil }))
        XCTAssertNil(Archive.found(on: .macOS, which: { $0 == "tar" ? "/usr/bin/tar" : nil }))
        XCTAssertNil(Archive.found(on: .wsl, which: { $0 == "tar" ? "/usr/bin/tar" : nil }))
    }

    func testAMachineWithNeitherSaysSo() {
        XCTAssertNil(Archive.found(on: .windows, which: { _ in nil }))
    }

    // MARK: Listing

    func testListingNamesEveryEntryWithoutUnpackingAnything() {
        XCTAssertEqual(unzip.listing(of: jar).arguments, ["-l", jar.nativePath])
        XCTAssertEqual(bsdtar.listing(of: jar).arguments, ["-tf", jar.nativePath])
    }

    // MARK: Reading one entry

    func testReadingOneEntrySendsItToStandardOutputRatherThanToDisk() {
        XCTAssertEqual(unzip.read("mkgmap-version.properties", from: jar).arguments,
                       ["-p", jar.nativePath, "mkgmap-version.properties"])
        // Without the O, bsdtar writes a file into the working directory and prints nothing.
        XCTAssertEqual(bsdtar.read("mkgmap-version.properties", from: jar).arguments,
                       ["-xOf", jar.nativePath, "mkgmap-version.properties"])
    }

    func testTheProgramItselfIsTheOneThatWasFound() {
        XCTAssertEqual(unzip.read("x", from: jar).executable, "/usr/bin/unzip")
        XCTAssertEqual(bsdtar.listing(of: jar).executable, #"C:\Windows\System32\tar.exe"#)
    }

    // MARK: Unpacking

    func testUnpackingCannotStopAndAskWhetherToOverwrite() {
        // Every child gets /dev/null for stdin, so an unzip that paused to ask "replace?"
        // would wait until it gave up.
        let into = URL(fileURLWithPath: "/tmp/staging", isDirectory: true)
        XCTAssertTrue(unzip.unpack(jar, into: into).arguments.contains("-o"))
        // bsdtar overwrites by default and asks nothing, so it needs no flag for it.
        XCTAssertEqual(bsdtar.unpack(jar, into: into).arguments,
                       ["-xf", jar.nativePath, "-C", into.nativePath])
    }

    func testThePatternsGoWhereEachToolExpectsThem() {
        let into = URL(fileURLWithPath: "/tmp/staging", isDirectory: true)
        // unzip's own argument order: patterns after the archive, before -d.
        XCTAssertEqual(unzip.unpack(jar, into: into, matching: ["styles/default/*"]).arguments,
                       ["-q", "-o", jar.nativePath, "styles/default/*", "-d", into.nativePath])
        XCTAssertEqual(bsdtar.unpack(jar, into: into, matching: ["styles/default/*"]).arguments,
                       ["-xf", jar.nativePath, "-C", into.nativePath, "styles/default/*"])
    }

    func testWithNoPatternTheWholeArchiveComesOut() {
        let into = URL(fileURLWithPath: "/tmp/staging", isDirectory: true)
        for archive in [unzip, bsdtar] {
            let arguments = archive.unpack(jar, into: into).arguments
            XCTAssertFalse(arguments.contains { $0.contains("*") }, "\(archive.name)")
        }
    }

    // MARK: When there is none

    func testWindowsIsNotSentToInstallSomethingThatIsPartOfWindows() {
        let note = Archive.missingNote(on: .windows)
        XCTAssertFalse(note.contains("winget"), note)
        XCTAssertTrue(note.contains("1803"), note)
        // Elsewhere it is an ordinary package and the line says how to install it.
        XCTAssertTrue(Archive.missingNote(on: .linux).contains("unzip"))
    }
}
