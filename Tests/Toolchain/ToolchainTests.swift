import XCTest
@testable import kmap

/// Finding Java, mkgmap and the rest, and remembering what was found.
///
/// These run against whatever is installed on the machine, so they assert that the
/// answers are consistent rather than what they are. The patch marker is pinned outright.
final class ToolchainTests: XCTestCase {

    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func toolchain() -> Toolchain { Toolchain(settings: SettingsStore()) }

    // MARK: A runtime against a whole JDK

    /// Writes an executable file at `path`, so the probe can find one.
    private func makeExecutable(_ url: URL, printing text: String = "") throws {
        #if os(Windows)
        throw XCTSkip("the fake tools are shell scripts")
        #else
        try ("#!/bin/sh\necho '\(text)'\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        #endif
    }

    func testAJavaWithNoCompilerBesideItIsNotAKit() throws {
        let java = directory.appendingPathComponent("java")
        try makeExecutable(java)
        let runtime = JavaRuntime(path: java.path, version: "21", options: [])
        XCTAssertFalse(runtime.isKit, "javac and jar are not there")

        try makeExecutable(directory.appendingPathComponent("javac"))
        try makeExecutable(directory.appendingPathComponent("jar"))
        XCTAssertTrue(runtime.isKit)
    }

    /// The machine's own Java is whatever it is; what is pinned here is that a runtime
    /// named in the settings is used to run and passed over when something has to compile.
    func testARuntimeIsRunButNotCompiledWith() throws {
        let java = directory.appendingPathComponent("java")
        try makeExecutable(java, printing: "openjdk version \"21.0.12\"")
        let settings = SettingsStore()
        // For this run only: nothing of the machine's own settings is written.
        settings.overrideForRun { $0.javaBinary = java.path }
        let tools = Toolchain(settings: settings)

        XCTAssertEqual(tools.findJava()?.path, java.path)
        XCTAssertNotEqual(tools.findJavaKit()?.path, java.path,
                          "a runtime cannot build the patch")
    }

    /// The screen used to answer "already installed" to anything ready, which left the
    /// runtime-without-javac row offering an install that did nothing, forever.
    func testAToolThatWorksButCannotDoEverythingStillTakesAnInstall() {
        var java = ToolStatus(id: "java", name: "Java", detail: "", state: .ready,
                              installable: true, moreToInstall: true)
        XCTAssertFalse(java.isFinished)

        java.moreToInstall = false
        XCTAssertTrue(java.isFinished, "ready and complete takes no install")

        let missing = ToolStatus(id: "mkgmap", name: "mkgmap", detail: "", state: .missing,
                                 installable: true)
        XCTAssertFalse(missing.isFinished)
    }

    func testTheJavaRowOffersAnInstallExactlyWhenItIsShortOfSomething() {
        let tools = Toolchain(settings: SettingsStore())
        guard let java = tools.status().first(where: { $0.id == "java" }),
              java.isReady else { return }
        // Whatever this machine carries, the row has to agree with the probe.
        if java.moreToInstall {
            XCTAssertTrue(java.installable, "an offer that leads nowhere")
            XCTAssertNotNil(java.note, "nothing says why it is offered again")
            XCTAssertNil(tools.findJavaKit(), "there is a compiler after all")
        }
    }

    // MARK: Probing

    func testWhateverJavaIsFoundIsSomethingThatCanBeRun() {
        guard let java = toolchain().findJava() else {
            return XCTAssertNil(toolchain().findMkgmap(),
                                "mkgmap cannot be usable without a Java to run it")
        }
        XCTAssertTrue(FileTools.isExecutable(java.path), java.path)
        // The macOS stub prints "Unable to locate a Java Runtime" and is not a runtime.
        XCTAssertTrue(java.version.lowercased().contains("version"), java.version)
        XCTAssertFalse(java.version.lowercased().contains("unable to locate"), java.version)
    }

    func testAProbeIsRunOnceAndThenRemembered() {
        // Asked from the render loop many times a second, so the probe is cached.
        let tools = toolchain()
        let first = tools.findJava()
        let started = Date()
        for _ in 0..<200 { _ = tools.findJava() }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1,
                          "the probe is being run again on every ask")
        XCTAssertEqual(first?.path, tools.findJava()?.path)
    }

    func testAskingForARefreshMakesItProbeAgainAndAgreeWithItself() {
        let tools = toolchain()
        let before = tools.findJava()?.path
        tools.invalidate()
        XCTAssertEqual(tools.findJava()?.path, before)
    }

    func testTheProbesAgreeWithEachOther() {
        // A version string for something that is not there sends a build off to run it.
        let tools = toolchain()
        if let mkgmap = tools.findMkgmap() {
            XCTAssertTrue(FileTools.exists(mkgmap.url), mkgmap.url.path)
            XCTAssertTrue(mkgmap.version.lowercased().contains("mkgmap"), mkgmap.version)
        }
        if let pyhgtmap = tools.findPyhgtmap() {
            XCTAssertTrue(FileTools.isExecutable(pyhgtmap.url.path))
            XCTAssertFalse(pyhgtmap.version.isEmpty)
        }
    }

    // MARK: What can be asked for by name

    func testEverythingTheScreenOffersToInstallCanBeAskedForOnTheCommandLine() {
        // The screen offers what `status()` reports for this machine; the command line
        // validates against a written list, and the two must not drift.
        for tool in toolchain().status() where tool.installable {
            XCTAssertTrue(Toolchain.installableIDs.contains(tool.id),
                          "\(tool.id) is offered but cannot be named")
        }
    }

    func testTheListIsNotDerivedFromWhatThisMachineHappensToBeMissing() {
        // `status()` depends on what this machine has, so the set of known names cannot
        // be derived from it.
        for expected in ["mkgmap", "mkgmap-patch", "pyhgtmap",
                         "java", "python", "unzip", "sea", "bounds"] {
            XCTAssertTrue(Toolchain.installableIDs.contains(expected), expected)
        }
        XCTAssertFalse(Toolchain.installableIDs.contains("mkgmpa"))
    }

    // MARK: A JVM that will not start

    func testTheOptionsGoInFrontOfTheJarBecauseThatIsWhereTheJvmLooks() {
        let plain = JavaRuntime(path: "/usr/bin/java", version: "21", options: [])
        XCTAssertEqual(plain.command(["-Xmx4g", "-jar", "mkgmap.jar"]),
                       ["-Xmx4g", "-jar", "mkgmap.jar"])

        // Anything after `-jar` belongs to the program, not to the JVM.
        let rescued = JavaRuntime(path: "/usr/bin/java", version: "21",
                                  options: ["-XX:-UseCompressedClassPointers"])
        XCTAssertEqual(rescued.command(["-Xmx4g", "-jar", "mkgmap.jar"]),
                       ["-XX:-UseCompressedClassPointers", "-Xmx4g", "-jar", "mkgmap.jar"])
    }

    func testJavacAndJarTakeTheSameOptionsThroughTheirOwnSpelling() {
        // They are JVMs as well, and they accept JVM options only behind `-J`.
        let rescued = JavaRuntime(path: "/usr/bin/java", version: "21",
                                  options: ["-XX:-UseCompressedClassPointers"])
        XCTAssertEqual(rescued.toolOptions, ["-J-XX:-UseCompressedClassPointers"])
        XCTAssertEqual(JavaRuntime(path: "/usr/bin/java", version: "21", options: []).toolOptions,
                       [])
    }

    func testAHealthyJavaCarriesNothingExtra() {
        // The option is found by asking; a JVM that starts plainly carries none.
        guard let java = toolchain().findJava() else {
            return XCTAssertNil(toolchain().findMkgmap())
        }
        #if canImport(Darwin)
        XCTAssertEqual(java.options, [], "a Mac has never needed one")
        #endif
        XCTAssertEqual(java.command(["-version"]), java.options + ["-version"])
    }

    // MARK: The patched jar

    func testTheMarkerIsWhatSaysAJarCarriesThePatch() throws {
        try XCTSkipUnless(Archive.isAvailable && Platform.which("zip") != nil,
                          "this reads a jar with the machine's zip and unzip")
        // By the marker inside rather than by the filename, so a jar copied or renamed
        // still answers honestly.
        let plain = directory.appendingPathComponent(Toolchain.patchedMkgmapName)
        try makeZip(at: plain, holding: ["something.properties": "nothing to see"])
        XCTAssertFalse(Toolchain.isPatched(plain), "named like the patched jar, and is not")

        let patched = directory.appendingPathComponent("renamed-by-someone.jar")
        try makeZip(at: patched, holding:
            [Toolchain.patchMarker: "patch-version: \(Toolchain.patchVersion)\n"])
        XCTAssertTrue(Toolchain.isPatched(patched), "carries the marker under another name")
    }

    func testAnOlderPatchReadsAsOutdatedNotAsPatched() throws {
        try XCTSkipUnless(Archive.isAvailable && Platform.which("zip") != nil,
                          "this reads a jar with the machine's zip and unzip")
        // A marker without a version cannot say which edits the jar stands for.
        let old = directory.appendingPathComponent("old-patch.jar")
        try makeZip(at: old, holding: [Toolchain.patchMarker: "option: --x-shape-clip-overlap\n"])
        XCTAssertEqual(Toolchain.patchVersion(of: old), 1)
        XCTAssertFalse(Toolchain.isPatched(old), "an old patch must ask to be rebuilt")

        let current = directory.appendingPathComponent("current-patch.jar")
        try makeZip(at: current, holding:
            [Toolchain.patchMarker: "patch-version: \(Toolchain.patchVersion)\n"])
        XCTAssertEqual(Toolchain.patchVersion(of: current), Toolchain.patchVersion)
        XCTAssertTrue(Toolchain.isPatched(current))

        let future = directory.appendingPathComponent("future-patch.jar")
        try makeZip(at: future, holding:
            [Toolchain.patchMarker: "patch-version: \(Toolchain.patchVersion + 5)\n"])
        XCTAssertTrue(Toolchain.isPatched(future), "a newer patch is not worse than ours")
    }

    func testSomethingThatIsNotAJarAtAllIsNotPatched() throws {
        XCTAssertFalse(Toolchain.isPatched(directory.appendingPathComponent("absent.jar")))
        let rubbish = directory.appendingPathComponent("rubbish.jar")
        try Data("not a zip".utf8).write(to: rubbish)
        XCTAssertFalse(Toolchain.isPatched(rubbish))
    }

    func testThePatchedJarIsLookedForUnderTheToolsFolder() {
        XCTAssertTrue(Toolchain.patchedMkgmapURL.path.hasPrefix(Paths.tools.path),
                      Toolchain.patchedMkgmapURL.path)
        XCTAssertEqual(Toolchain.patchedMkgmapURL.lastPathComponent,
                       Toolchain.patchedMkgmapName)
    }

    /// A real zip, built with the machine's own `zip` so that `unzip -l` reads it the way
    /// the check under test does.
    private func makeZip(at url: URL, holding files: [String: String]) throws {
        let zipBinary = try XCTUnwrap(Platform.which("zip"), "no zip on this machine")
        let staging = directory.appendingPathComponent("staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for (name, body) in files {
            try body.write(to: staging.appendingPathComponent(name), atomically: true,
                           encoding: .utf8)
        }
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: zipBinary)
        zip.arguments = ["-q", "-r", url.path, "."]
        zip.currentDirectoryURL = staging
        zip.standardOutput = FileHandle.nullDevice
        zip.standardError = FileHandle.nullDevice
        try zip.run()
        waitForExit(zip)
        try FileManager.default.removeItem(at: staging)
    }
}
