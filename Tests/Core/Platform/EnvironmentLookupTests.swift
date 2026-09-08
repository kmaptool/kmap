import XCTest
@testable import kmap

/// Reading an environment variable on a machine that may not agree about its name.
final class EnvironmentLookupTests: XCTestCase {

    func testWindowsSpellsItPathAndMeansTheSameVariable() {
        // Windows writes the name as `Path`, and a case-sensitive lookup for `PATH`
        // would answer nil.
        let environment = ["Path": #"C:\Windows"#, "ProgramW6432": "x"]
        XCTAssertEqual(environment.variable("PATH", on: .windows), #"C:\Windows"#)
        XCTAssertEqual(environment.variable("path", on: .windows), #"C:\Windows"#)
    }

    func testTheUnixesAreExactBecauseThereTheCaseIsRealMeaning() {
        // `Path` and `PATH` are two different variables on Linux.
        let environment = ["Path": "/opt/bin"]
        XCTAssertNil(environment.variable("PATH", on: .linux))
        XCTAssertNil(environment.variable("PATH", on: .macOS))
        XCTAssertNil(environment.variable("PATH", on: .wsl))
        XCTAssertEqual(environment.variable("Path", on: .linux), "/opt/bin")
    }

    func testAnExactMatchIsTakenWithoutLookingFurther() {
        let environment = ["PATH": "right", "Path": "wrong"]
        XCTAssertEqual(environment.variable("PATH", on: .windows), "right")
    }

    func testSomethingThatIsNotThereIsNotThereEitherWay() {
        XCTAssertNil([String: String]().variable("PATH", on: .windows))
        XCTAssertNil(["HOME": "/home/k"].variable("PATH", on: .windows))
    }

    func testTheProgramSearchReadsAPathSpelledTheWindowsWay() {
        let found = Platform.which("java", environment: ["Path": #"C:\jdk\bin"#],
                                   on: .windows,
                                   exists: { $0 == #"C:\jdk\bin\java.exe"# })
        XCTAssertEqual(found, #"C:\jdk\bin\java.exe"#)
    }

    func testTheOtherWindowsVariablesAreReadTheSameWay() {
        // Every Windows variable is read case-insensitively, not only `Path`.
        XCTAssertTrue(Platform.searchPath(["systemroot": #"D:\Windows"#], on: .windows)
                          .contains(#"D:\Windows\System32"#))
        XCTAssertEqual(Platform.executableSuffixes(["pathext": ".EXE"], on: .windows),
                       ["", ".exe"])
        XCTAssertTrue(Paths.defaultRoot(.windows, environment: ["localappdata": #"D:\AppData"#])
                          .nativePath.contains("AppData"))
    }
}
