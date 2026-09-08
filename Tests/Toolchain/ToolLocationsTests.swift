import XCTest
@testable import kmap

/// Where the programs kmap does not ship are kept, on each kind of machine.
///
/// Nothing here touches the machine it is asked about: the environment and the directory
/// listing are handed in, so the Windows cases are checkable on any platform.
final class ToolLocationsTests: XCTestCase {

    private func nothing(_ path: String) -> [String] { [] }
    private func noProgram(_ name: String, _ environment: [String: String]) -> String? { nil }

    // MARK: Java, on the Unixes

    func testWhatThePersonSetInSettingsIsTriedBeforeAnythingElse() {
        let candidates = ToolLocations.java(on: .linux, configured: "/opt/jdk21/bin/java",
                                            environment: ["JAVA_HOME": "/usr/lib/jvm/one"],
                                            which: noProgram, contents: nothing,
                                            macJavaHome: { nil })
        XCTAssertEqual(candidates.first, "/opt/jdk21/bin/java")
    }

    func testJavaHomeBeatsThePathBecauseItIsWhatTheVersionManagerSet() {
        let candidates = ToolLocations.java(on: .linux,
                                            environment: ["JAVA_HOME": "/home/k/.sdkman/candidates/java/current"],
                                            which: { _, _ in "/usr/bin/java" },
                                            contents: nothing, macJavaHome: { nil })
        XCTAssertEqual(candidates.first, "/home/k/.sdkman/candidates/java/current/bin/java")
        XCTAssertTrue(candidates.contains("/usr/bin/java"))
    }

    func testTheWellKnownPlacesAreStillThereBehindThePath() {
        let candidates = ToolLocations.java(on: .linux, environment: [:], which: noProgram,
                                            contents: nothing, macJavaHome: { nil })
        XCTAssertEqual(candidates.last, "/usr/bin/java")
        XCTAssertTrue(candidates.contains("/usr/lib/jvm/default-java/bin/java"))
    }

    func testTheMacShimIsAskedOnAMacAndNowhereElse() {
        var asked = 0
        let home = { () -> String? in asked += 1; return "/Library/Java/JavaVirtualMachines/21.jdk/Contents/Home" }
        let mac = ToolLocations.java(on: .macOS, environment: [:], which: noProgram,
                                     contents: nothing, macJavaHome: home)
        XCTAssertEqual(mac.first,
                       "/Library/Java/JavaVirtualMachines/21.jdk/Contents/Home/bin/java")
        XCTAssertEqual(asked, 1)
        // On Linux there is no such program, and asking would start a process that fails.
        _ = ToolLocations.java(on: .linux, environment: [:], which: noProgram,
                               contents: nothing, macJavaHome: home)
        _ = ToolLocations.java(on: .windows, environment: [:], which: noProgram,
                               contents: nothing, macJavaHome: home)
        XCTAssertEqual(asked, 1)
    }

    // MARK: Java, on Windows

    func testAWindowsJdkIsFoundByLookingInsideTheVendorsFolder() {
        // Every vendor installs into a folder named after the version, so the folder
        // listing has to be read.
        let candidates = ToolLocations.java(
            on: .windows, environment: ["ProgramFiles": #"C:\Program Files"#],
            which: noProgram,
            contents: { $0 == #"C:\Program Files\Microsoft"# ? ["jdk-21.0.5.11-hotspot"] : [] },
            macJavaHome: { nil })
        XCTAssertEqual(candidates.first,
                       #"C:\Program Files\Microsoft\jdk-21.0.5.11-hotspot\bin\java.exe"#)
    }

    func testTheNewestJdkIsTriedFirstEvenThoughItSortsEarlier() {
        // mkgmap needs 17 or better, and "jdk-9" sorts after "jdk-21" as text.
        let candidates = ToolLocations.java(
            on: .windows, environment: [:], which: noProgram,
            contents: { $0.hasSuffix(#"\Java"#) ? ["jdk-9", "jdk-21", "jdk-17", "jre-8"] : [] },
            macJavaHome: { nil })
        let names = candidates.map { $0.split(separator: "\\").dropLast(2).last.map(String.init) ?? "" }
        XCTAssertEqual(names, ["jdk-21", "jdk-17", "jdk-9", "jre-8"])
    }

    func testAnythingThatIsNotAJdkFolderIsIgnored() {
        let candidates = ToolLocations.java(
            on: .windows, environment: [:], which: noProgram,
            contents: { $0.hasSuffix(#"\Microsoft"#) ? ["jdk-21", "Edge", "OneDrive", "VFS"] : [] },
            macJavaHome: { nil })
        XCTAssertEqual(candidates.count, 1)
        XCTAssertTrue(candidates[0].contains("jdk-21"))
    }

    func testJavaHomeOnWindowsIsSpelledTheWindowsWay() {
        let candidates = ToolLocations.java(
            on: .windows, environment: ["JAVA_HOME": #"C:\Program Files\Microsoft\jdk-21"#],
            which: noProgram, contents: nothing, macJavaHome: { nil })
        XCTAssertEqual(candidates.first, #"C:\Program Files\Microsoft\jdk-21\bin\java.exe"#)
    }

    func testATrailingBackslashOnJavaHomeDoesNotBecomeADoubleOne() {
        // Some installers set it with one, and `C:\jdk\\bin\java.exe` opens nothing.
        let candidates = ToolLocations.java(on: .windows, environment: ["JAVA_HOME": #"C:\jdk\"#],
                                            which: noProgram, contents: nothing,
                                            macJavaHome: { nil })
        XCTAssertEqual(candidates.first, #"C:\jdk\bin\java.exe"#)
    }

    func testAPerUserInstallIsLookedForToo() {
        // An installer run without administrator rights installs per user.
        let candidates = ToolLocations.java(
            on: .windows, environment: ["LOCALAPPDATA": #"C:\Users\k\AppData\Local"#],
            which: noProgram,
            contents: { $0 == #"C:\Users\k\AppData\Local\Programs\Eclipse Adoptium"#
                ? ["jdk-21.0.5.11-hotspot"] : [] },
            macJavaHome: { nil })
        XCTAssertEqual(candidates.count, 1)
        XCTAssertTrue(candidates[0].hasPrefix(#"C:\Users\k\AppData\Local"#))
    }

    func testProgramFilesIsReadFromTheEnvironmentBecauseItIsNotAlwaysOnC() {
        let candidates = ToolLocations.java(
            on: .windows, environment: ["ProgramFiles": #"D:\Programs"#], which: noProgram,
            contents: { $0.hasPrefix(#"D:\Programs"#) ? ["jdk-21"] : [] },
            macJavaHome: { nil })
        XCTAssertEqual(candidates.first, #"D:\Programs\Microsoft\jdk-21\bin\java.exe"#)
    }

    // MARK: Version order

    func testVersionsAreComparedByTheirNumbersAndNotAsText() {
        XCTAssertTrue(ToolLocations.newer("jdk-21", than: "jdk-9"))
        XCTAssertTrue(ToolLocations.newer("jdk-21.0.5", than: "jdk-21.0.4"))
        XCTAssertTrue(ToolLocations.newer("jdk-17.0.9", than: "jdk-17"))
        XCTAssertFalse(ToolLocations.newer("jre-8", than: "jdk-21"))
        XCTAssertFalse(ToolLocations.newer("jdk-21", than: "jdk-21"))
    }

    // MARK: The rest of the JDK

    func testJavacIsFoundBesideJavaAndNotOnThePath() {
        // The same JDK, not merely a javac: classes compiled by one and packed by
        // another's jar come out unloadable.
        XCTAssertEqual(ToolLocations.companion("javac", of: "/usr/lib/jvm/jdk-21/bin/java",
                                               on: .linux),
                       "/usr/lib/jvm/jdk-21/bin/javac")
    }

    func testOnWindowsItIsJavacExeAndSayingOtherwiseLosesTheJdk() {
        // Without the `.exe` suffix the check finds nothing on Windows.
        let javac = ToolLocations.companion("javac",
                                            of: #"C:\Program Files\Microsoft\jdk-21\bin\java.exe"#,
                                            on: .windows)
        XCTAssertTrue(javac.hasSuffix("javac.exe"), javac)
        XCTAssertTrue(javac.contains("jdk-21"), javac)
        let jar = ToolLocations.companion("jar", of: #"C:\jdk\bin\java.exe"#, on: .windows)
        XCTAssertTrue(jar.hasSuffix("jar.exe"), jar)
    }

    // MARK: Python

    func testPythonIsTakenFromThePathFirstSoAVersionManagerWins() {
        let candidates = ToolLocations.python(on: .linux, environment: [:],
                                              which: { name, _ in
                                                  name == "python3" ? "/home/k/.pyenv/shims/python3" : nil
                                              },
                                              contents: nothing)
        XCTAssertEqual(candidates.first, "/home/k/.pyenv/shims/python3")
        XCTAssertEqual(candidates.last, "/usr/bin/python3")
    }

    func testWindowsAlsoAnswersToTheNameWithoutTheThree() {
        // `python3.exe` exists in a virtual environment and in an MSYS install; the
        // ordinary Windows one is `python.exe`.
        let candidates = ToolLocations.python(on: .windows, environment: [:],
                                              which: { name, _ in
                                                  name == "python" ? #"C:\Python312\python.exe"# : nil
                                              },
                                              contents: nothing)
        XCTAssertEqual(candidates.first, #"C:\Python312\python.exe"#)
    }

    func testTheStoreStubIsNeverOfferedBecauseRunningItOpensAShop() {
        // Windows ships zero-byte stubs in WindowsApps that open the store; they sit on
        // every account's PATH and answer `which`.
        let stub = #"C:\Users\k\AppData\Local\Microsoft\WindowsApps\python3.exe"#
        XCTAssertTrue(ToolLocations.isAppExecutionAlias(stub))
        let candidates = ToolLocations.python(on: .windows, environment: [:],
                                              which: { _, _ in stub }, contents: nothing)
        XCTAssertFalse(candidates.contains(stub))
    }

    func testAWindowsPythonIsFoundWhereItsInstallerPutsIt() {
        let candidates = ToolLocations.python(
            on: .windows, environment: ["LOCALAPPDATA": #"C:\Users\k\AppData\Local"#],
            which: noProgram,
            contents: { $0 == #"C:\Users\k\AppData\Local\Programs\Python"#
                ? ["Python39", "Python312"] : [] })
        XCTAssertEqual(candidates.first,
                       #"C:\Users\k\AppData\Local\Programs\Python\Python312\python.exe"#,
                       "and the newest of them first")
    }

    // MARK: Inside a virtual environment

    func testAVirtualEnvironmentKeepsItsProgramsWhereThatPythonPutsThem() {
        let venv = URL(fileURLWithPath: "/home/k/.kmap/tools/venv", isDirectory: true)
        XCTAssertEqual(ToolLocations.inVirtualEnvironment("pip", of: venv, on: .linux).path,
                       "/home/k/.kmap/tools/venv/bin/pip")
        // `python -m venv` writes into Scripts/ with the extension on Windows, not bin/.
        let windows = ToolLocations.inVirtualEnvironment("pyhgtmap", of: venv, on: .windows)
        XCTAssertTrue(windows.nativePath.hasSuffix("venv/Scripts/pyhgtmap.exe")
                      || windows.nativePath.hasSuffix(#"venv\Scripts\pyhgtmap.exe"#),
                      windows.nativePath)
    }

    // MARK: Java's own notion of a path list

    func testTheClasspathIsSeparatedTheWayJavaSeparatesItOnThatMachine() {
        XCTAssertEqual(ToolLocations.classpathSeparator(on: .macOS), ":")
        XCTAssertEqual(ToolLocations.classpathSeparator(on: .linux), ":")
        XCTAssertEqual(ToolLocations.classpathSeparator(on: .wsl), ":",
                       "WSL runs a Linux JVM on Linux paths, whatever the desktop is")
        // A colon there would cut `C:\a.jar` into a classpath entry called "C".
        XCTAssertEqual(ToolLocations.classpathSeparator(on: .windows), ";")
    }
}
