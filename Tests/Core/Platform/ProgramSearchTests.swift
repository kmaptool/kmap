import XCTest
@testable import kmap

/// Finding a program by name, the way the shell would.
///
/// The environment and the filesystem are handed in, so any platform's rules can be
/// exercised from any other. The Windows rules — semicolons, and an extension that has
/// to be guessed — share nothing with the Unix ones.
final class ProgramSearchTests: XCTestCase {

    // MARK: The search path

    func testSomethingOnThePathIsFoundWhereThePathSaysItIs() {
        let found = Platform.which("pyhgtmap", environment: ["PATH": "/opt/bin:/usr/bin"],
                                   on: .linux, exists: { $0 == "/usr/bin/pyhgtmap" })
        XCTAssertEqual(found, "/usr/bin/pyhgtmap")
    }

    func testTheEarlierDirectoryOnThePathWins() {
        let found = Platform.which("python3", environment: ["PATH": "/opt/bin:/usr/bin"],
                                   on: .linux, exists: { _ in true })
        XCTAssertEqual(found, "/opt/bin/python3")
    }

    func testAPathThatIsAlreadyAPathIsNotSearchedFor() {
        XCTAssertEqual(Platform.which("/usr/local/bin/java", environment: [:], on: .linux,
                                      exists: { _ in true }), "/usr/local/bin/java")
        XCTAssertNil(Platform.which("/usr/local/bin/java", environment: [:], on: .linux,
                                    exists: { _ in false }))
    }

    func testAnEmptyPathStillHasSomewhereToLook() {
        // PATH can be absent when the program is started from a launcher or a service.
        XCTAssertEqual(Platform.which("unzip", environment: [:], on: .linux,
                                      exists: { $0 == "/usr/bin/unzip" }), "/usr/bin/unzip")
    }

    func testNothingIsFoundWhenNothingIsThere() {
        XCTAssertNil(Platform.which("kdialog", environment: ["PATH": "/usr/bin"], on: .linux,
                                    exists: { _ in false }))
    }

    // MARK: Windows spells the path differently

    func testWindowsSplitsThePathOnSemicolonsBecauseEveryEntryStartsWithADriveLetter() {
        let path = #"C:\Program Files\Java\bin;C:\Windows\System32"#
        XCTAssertEqual(Array(Platform.searchPath(["PATH": path], on: .windows).prefix(2)),
                       [#"C:\Program Files\Java\bin"#, #"C:\Windows\System32"#])
        // Split on colons instead and every entry loses its drive: "C", "\Program Files…".
        XCTAssertEqual(Platform.searchPath(["PATH": path], on: .linux).first, "C")
    }

    func testWindowsWithNoPathAtAllStillKnowsWhereWindowsKeepsItsPrograms() {
        let fallbacks = Platform.searchPath(["SystemRoot": #"D:\Windows"#], on: .windows)
        XCTAssertEqual(fallbacks, [#"D:\Windows\System32"#, #"D:\Windows"#])
        // With nothing set at all, the conventional location.
        XCTAssertTrue(Platform.searchPath([:], on: .windows).contains(#"C:\Windows\System32"#))
    }

    func testWhatIsAlreadyOnThePathIsNotAddedToItAgain() {
        let path = #"C:\Windows\System32"#
        XCTAssertEqual(Platform.searchPath(["PATH": path, "SystemRoot": #"C:\Windows"#],
                                           on: .windows),
                       [#"C:\Windows\System32"#, #"C:\Windows"#])
    }

    // MARK: What makes a file a program

    func testUnixDecidesByTheExecuteBitAndSoHasNoSuffixesToTry() {
        XCTAssertEqual(Platform.executableSuffixes([:], on: .linux), [""])
        XCTAssertEqual(Platform.executableSuffixes(["PATHEXT": ".EXE"], on: .macOS), [""],
                       "PATHEXT means nothing here even when something has set it")
    }

    func testWindowsDecidesByExtensionAndPathextIsTheList() {
        let suffixes = Platform.executableSuffixes(["PATHEXT": ".COM;.EXE;.BAT"], on: .windows)
        XCTAssertEqual(suffixes, ["", ".com", ".exe", ".bat"])
    }

    func testWindowsWithNoPathextFallsBackToTheOnesEveryWindowsHas() {
        XCTAssertEqual(Platform.executableSuffixes([:], on: .windows),
                       ["", ".com", ".exe", ".bat", ".cmd"])
    }

    func testJavaIsFoundAsJavaExeBecauseNobodyTypesTheExtension() {
        // The name asked for is "java" and the file is java.exe.
        let found = Platform.which("java",
                                   environment: ["PATH": #"C:\Program Files\Java\bin"#],
                                   on: .windows,
                                   exists: { $0 == #"C:\Program Files\Java\bin\java.exe"# })
        XCTAssertEqual(found, #"C:\Program Files\Java\bin\java.exe"#)
    }

    func testANameGivenWithItsExtensionIsFoundAsWrittenAndNotAsExeExe() {
        // A name already carrying its extension must not gain a second one.
        let found = Platform.which("powershell.exe", environment: ["PATH": #"C:\Windows"#],
                                   on: .windows,
                                   exists: { $0 == #"C:\Windows\powershell.exe"# })
        XCTAssertEqual(found, #"C:\Windows\powershell.exe"#)
    }

    func testTheDirectoryVariesSlowerThanTheExtension() {
        // Both exist: the first directory's copy wins, whatever its extension.
        let found = Platform.which("mkgmap",
                                   environment: ["PATH": #"C:\Tools;C:\Other"#],
                                   on: .windows,
                                   exists: { $0 == #"C:\Tools\mkgmap.bat"#
                                          || $0 == #"C:\Other\mkgmap"# })
        XCTAssertEqual(found, #"C:\Tools\mkgmap.bat"#)
    }

    func testABackslashPathIsUsedAsGivenRatherThanJoinedOntoEveryPathEntry() {
        let full = #"C:\Program Files\Java\bin\java.exe"#
        XCTAssertEqual(Platform.which(full, environment: ["PATH": #"C:\Windows"#],
                                      on: .windows, exists: { $0 == full }), full)
        // And the extension is still filled in for one that was given without it.
        XCTAssertEqual(Platform.which(#"C:\Tools\splitter"#, environment: [:], on: .windows,
                                      exists: { $0 == #"C:\Tools\splitter.bat"# }),
                       #"C:\Tools\splitter.bat"#)
    }

    func testABackslashIsJustACharacterOnLinuxAndNotAPathSeparator() {
        // A file may legitimately be called that on Linux, so it is searched for by name.
        XCTAssertEqual(Platform.which(#"odd\name"#, environment: ["PATH": "/usr/bin"],
                                      on: .linux, exists: { $0 == #"/usr/bin/odd\name"# }),
                       #"/usr/bin/odd\name"#)
    }

    func testADirectoryThatAlreadyEndsInASeparatorDoesNotGetASecondOne() {
        XCTAssertEqual(Platform.which("java", environment: ["PATH": #"C:\Tools\"#],
                                      on: .windows, exists: { $0 == #"C:\Tools\java.exe"# }),
                       #"C:\Tools\java.exe"#)
    }
}
