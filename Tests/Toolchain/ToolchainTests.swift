import XCTest

@testable import kmap

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
        try FileTools.write("#!/bin/sh\necho '\(text)'\n", to: url)
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
        XCTAssertNotEqual(
            tools.findJavaKit()?.path,
            java.path,
            "a runtime cannot build the patch"
        )
    }

    /// The screen used to answer "already installed" to anything ready, which left the
    /// runtime-without-javac row offering an install that did nothing, forever.
    func testAToolThatWorksButCannotDoEverythingStillTakesAnInstall() {
        var java = ToolStatus(
            id: "java",
            name: "Java",
            detail: "",
            state: .ready,
            installable: true,
            moreToInstall: true
        )
        XCTAssertFalse(java.isFinished)

        java.moreToInstall = false
        XCTAssertTrue(java.isFinished, "ready and complete takes no install")

        let missing = ToolStatus(
            id: "mkgmap",
            name: "mkgmap",
            detail: "",
            state: .missing,
            installable: true
        )
        XCTAssertFalse(missing.isFinished)
    }

    func testTheJavaRowOffersAnInstallExactlyWhenItIsShortOfSomething() {
        let tools = Toolchain(settings: SettingsStore())
        guard let java = tools.status().first(where: { $0.id == "java" }),
            java.isReady
        else { return }
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
            return XCTAssertNil(
                toolchain().findMkgmap(),
                "mkgmap cannot be usable without a Java to run it"
            )
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
        XCTAssertLessThan(
            Date().timeIntervalSince(started),
            1,
            "the probe is being run again on every ask"
        )
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
            XCTAssertTrue(
                Toolchain.installableIDs.contains(tool.id),
                "\(tool.id) is offered but cannot be named"
            )
        }
    }

    func testTheListIsNotDerivedFromWhatThisMachineHappensToBeMissing() {
        // `status()` depends on what this machine has, so the set of known names cannot
        // be derived from it.
        for expected in [
            "mkgmap", "mkgmap-patch", "pyhgtmap",
            "java", "python", "unzip", "sea", "bounds"
        ] {
            XCTAssertTrue(Toolchain.installableIDs.contains(expected), expected)
        }
        XCTAssertFalse(Toolchain.installableIDs.contains("mkgmpa"))
    }

    // MARK: A JVM that will not start

    func testTheOptionsGoInFrontOfTheJarBecauseThatIsWhereTheJvmLooks() {
        let plain = JavaRuntime(path: "/usr/bin/java", version: "21", options: [])
        XCTAssertEqual(
            plain.command(["-Xmx4g", "-jar", "mkgmap.jar"]),
            ["-Xmx4g", "-jar", "mkgmap.jar"]
        )

        // Anything after `-jar` belongs to the program, not to the JVM.
        let rescued = JavaRuntime(
            path: "/usr/bin/java",
            version: "21",
            options: ["-XX:-UseCompressedClassPointers"]
        )
        XCTAssertEqual(
            rescued.command(["-Xmx4g", "-jar", "mkgmap.jar"]),
            ["-XX:-UseCompressedClassPointers", "-Xmx4g", "-jar", "mkgmap.jar"]
        )
    }

    func testJavacAndJarTakeTheSameOptionsThroughTheirOwnSpelling() {
        // They are JVMs as well, and they accept JVM options only behind `-J`.
        let rescued = JavaRuntime(
            path: "/usr/bin/java",
            version: "21",
            options: ["-XX:-UseCompressedClassPointers"]
        )
        XCTAssertEqual(rescued.toolOptions, ["-J-XX:-UseCompressedClassPointers"])
        XCTAssertEqual(
            JavaRuntime(path: "/usr/bin/java", version: "21", options: []).toolOptions,
            []
        )
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
        try XCTSkipUnless(
            Archive.isAvailable && Platform.which("zip") != nil,
            "this reads a jar with the machine's zip and unzip"
        )
        // By the marker inside rather than by the filename, so a jar copied or renamed
        // still answers honestly.
        let plain = directory.appendingPathComponent(Toolchain.patchedMkgmapName)
        try makeZip(at: plain, holding: ["something.properties": "nothing to see"])
        XCTAssertFalse(Toolchain.isPatched(plain), "named like the patched jar, and is not")

        let patched = directory.appendingPathComponent("renamed-by-someone.jar")
        try makeZip(at: patched, holding: [Toolchain.patchMarker: "patch-version: \(Toolchain.patchVersion)\n"])
        XCTAssertTrue(Toolchain.isPatched(patched), "carries the marker under another name")
    }

    /// Only a jar that carries an older patch, or one built for a newer Java, is rebuilt on
    /// its own: one that was never patched stays as it is, and the current one has nothing
    /// to rebuild.
    func testKmapsOwnJavaIsTakenOverAFoundOneOnlyWhereItIsNewer() {
        func java(_ path: String, _ version: String) -> JavaRuntime {
            JavaRuntime(path: path, version: #"openjdk version "\#(version)""#, options: [])
        }
        let system21 = java("/usr/bin/java", "21.0.12")
        let own25 = java("/k/tools/jdk/bin/java", "25.0.4")
        XCTAssertEqual(Toolchain.preferred(found: system21, own: own25), own25, "25 starts mkgmap warm")
        XCTAssertEqual(Toolchain.preferred(found: java("/usr/bin/java", "25.0.1"), own: own25).path, "/usr/bin/java")
        XCTAssertEqual(
            Toolchain.preferred(found: java("/opt/jdk27/bin/java", "27"), own: own25).path,
            "/opt/jdk27/bin/java"
        )
        XCTAssertEqual(Toolchain.preferred(found: system21, own: nil), system21)
    }

    func testOnlyTheSettingAndJavaHomeNameAJava() {
        XCTAssertEqual(
            ToolLocations.namedJava(
                on: .linux,
                configured: "/x/java",
                environment: ["JAVA_HOME": "/jdk", "PATH": "/usr/bin"]
            ),
            ["/x/java", "/jdk/bin/java"]
        )
        XCTAssertEqual(ToolLocations.namedJava(on: .linux, configured: "", environment: ["PATH": "/usr/bin"]), [])
    }

    func testOnlyAnOlderPatchOrOneTooNewForTheJavaIsStale() throws {
        try XCTSkipUnless(
            Archive.isAvailable && Platform.which("zip") != nil,
            "this reads a jar with the machine's zip and unzip"
        )
        let stock = directory.appendingPathComponent("stock.jar")
        try makeZip(at: stock, holding: ["something.properties": "nothing to see"])
        XCTAssertFalse(Toolchain.isStalePatch(stock, runtime: 21), "never patched")
        XCTAssertFalse(Toolchain.isStalePatch(directory.appendingPathComponent("absent.jar"), runtime: 21))

        let current = directory.appendingPathComponent("current.jar")
        try makeZip(at: current, holding: [Toolchain.patchMarker: "patch-version: \(Toolchain.patchVersion)\n"])
        XCTAssertFalse(Toolchain.isStalePatch(current, runtime: 21))

        let older = directory.appendingPathComponent("older.jar")
        try makeZip(at: older, holding: [Toolchain.patchMarker: "patch-version: \(Toolchain.patchVersion - 1)\n"])
        XCTAssertTrue(Toolchain.isStalePatch(older, runtime: 21))

        let unnumbered = directory.appendingPathComponent("unnumbered.jar")
        try makeZip(at: unnumbered, holding: [Toolchain.patchMarker: "option: --x-shape-clip-overlap\n"])
        XCTAssertTrue(Toolchain.isStalePatch(unnumbered, runtime: 21), "from before the marker carried a number")

        let tooNew = directory.appendingPathComponent("too-new.jar")
        try makeZip(
            at: tooNew,
            holding: [Toolchain.patchMarker: "patch-version: \(Toolchain.patchVersion)\nclass-release: 25\n"]
        )
        XCTAssertTrue(Toolchain.isStalePatch(tooNew, runtime: 21), "its classes do not load on 21")
        XCTAssertFalse(Toolchain.isStalePatch(tooNew, runtime: 25))
    }

    func testTheMarkerSaysWhichJavaThePatchIsCompiledFor() throws {
        try XCTSkipUnless(
            Archive.isAvailable && Platform.which("zip") != nil,
            "this reads a jar with the machine's zip and unzip"
        )
        let jar = directory.appendingPathComponent("released.jar")
        try makeZip(at: jar, holding: [Toolchain.patchMarker: "patch-version: 22\r\nclass-release: 21\r\n"])
        let state = Toolchain.patchState(of: jar)
        XCTAssertEqual(state.version, 22)
        XCTAssertEqual(state.release, 21)
        let older = directory.appendingPathComponent("older-marker.jar")
        try makeZip(at: older, holding: [Toolchain.patchMarker: "patch-version: 22\n"])
        XCTAssertNil(Toolchain.patchState(of: older).release, "a marker from before it said")
    }

    func testAnOlderPatchReadsAsOutdatedNotAsPatched() throws {
        try XCTSkipUnless(
            Archive.isAvailable && Platform.which("zip") != nil,
            "this reads a jar with the machine's zip and unzip"
        )
        // A marker without a version cannot say which edits the jar stands for.
        let old = directory.appendingPathComponent("old-patch.jar")
        try makeZip(at: old, holding: [Toolchain.patchMarker: "option: --x-shape-clip-overlap\n"])
        XCTAssertEqual(Toolchain.patchVersion(of: old), 1)
        XCTAssertFalse(Toolchain.isPatched(old), "an old patch must ask to be rebuilt")

        let current = directory.appendingPathComponent("current-patch.jar")
        try makeZip(at: current, holding: [Toolchain.patchMarker: "patch-version: \(Toolchain.patchVersion)\n"])
        XCTAssertEqual(Toolchain.patchVersion(of: current), Toolchain.patchVersion)
        XCTAssertTrue(Toolchain.isPatched(current))

        let future = directory.appendingPathComponent("future-patch.jar")
        try makeZip(at: future, holding: [Toolchain.patchMarker: "patch-version: \(Toolchain.patchVersion + 5)\n"])
        XCTAssertTrue(Toolchain.isPatched(future), "a newer patch is not worse than ours")
    }

    func testSomethingThatIsNotAJarAtAllIsNotPatched() throws {
        XCTAssertFalse(Toolchain.isPatched(directory.appendingPathComponent("absent.jar")))
        let rubbish = directory.appendingPathComponent("rubbish.jar")
        try FileTools.write(Data("not a zip".utf8), to: rubbish)
        XCTAssertFalse(Toolchain.isPatched(rubbish))
    }

    func testThePatchedJarIsLookedForUnderTheToolsFolder() {
        XCTAssertTrue(
            Toolchain.patchedMkgmapURL.path.hasPrefix(Paths.tools.path),
            Toolchain.patchedMkgmapURL.path
        )
        XCTAssertEqual(
            Toolchain.patchedMkgmapURL.lastPathComponent,
            Toolchain.patchedMkgmapName
        )
    }

    /// A real zip, built with the machine's own `zip` so that `unzip -l` reads it the way
    /// the check under test does.
    private func makeZip(at url: URL, holding files: [String: String]) throws {
        let zipBinary = try XCTUnwrap(Platform.which("zip"), "no zip on this machine")
        let staging = directory.appendingPathComponent("staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for (name, body) in files {
            try body.write(
                to: staging.appendingPathComponent(name),
                atomically: true,
                encoding: .utf8
            )
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

    // MARK: What must not be installed at the same time

    func testAnInstallNamesWhatItWouldFetchOnItsOwn() {
        XCTAssertEqual(Toolchain.prerequisites(of: "mkgmap-patch"), ["java", "mkgmap"])
        XCTAssertEqual(Toolchain.prerequisites(of: "mkgmap"), ["unzip"])
        XCTAssertEqual(Toolchain.prerequisites(of: "pyhgtmap"), ["python"])
        XCTAssertTrue(Toolchain.prerequisites(of: "sea").isEmpty)
        XCTAssertTrue(Toolchain.prerequisites(of: "no-such-tool").isEmpty)
    }

    func testOverlapReadsBothWays() {
        XCTAssertTrue(Toolchain.overlap("mkgmap-patch", "mkgmap"))
        XCTAssertTrue(Toolchain.overlap("mkgmap", "mkgmap-patch"))
        XCTAssertFalse(Toolchain.overlap("sea", "bounds"), "two packs fetch different things")
        XCTAssertFalse(Toolchain.overlap("sea", "sea"), "a tool is not its own prerequisite")
    }

    // MARK: Which Java the patch is compiled for

    func testThePatchIsCompiledForAnOlderJavaThatRunsIt() {
        // A JDK 25 compiling for a Java 21 runtime: classes for 25 would not load there.
        XCTAssertEqual(Toolchain.releaseOptions(kit: 25, runtime: 21), ["--release", "21"])
        XCTAssertEqual(Toolchain.releaseOptions(kit: 25, runtime: 8), ["--release", "8"])
    }

    func testTheSameOrANewerRuntimeTakesTheJDKsOwnTarget() {
        XCTAssertEqual(Toolchain.releaseOptions(kit: 25, runtime: 25), [])
        XCTAssertEqual(Toolchain.releaseOptions(kit: 21, runtime: 25), [])
        // A JDK 8 knows no --release, and an unread version decides nothing.
        XCTAssertEqual(Toolchain.releaseOptions(kit: 8, runtime: 8), [])
        XCTAssertEqual(Toolchain.releaseOptions(kit: nil, runtime: 21), [])
        XCTAssertEqual(Toolchain.releaseOptions(kit: 25, runtime: nil), [])
        // javac 8 has no --release at all, whatever runs the jar.
        XCTAssertEqual(Toolchain.releaseOptions(kit: 8, runtime: 7), [])
    }

    func testTheMarkerRecordsTheReleaseTheClassesAreFor() {
        XCTAssertEqual(Toolchain.classRelease(kit: 25, runtime: 21), 21)
        XCTAssertEqual(Toolchain.classRelease(kit: 25, runtime: 27), 25)
        XCTAssertEqual(Toolchain.classRelease(kit: 25, runtime: nil), 25)
        XCTAssertEqual(Toolchain.classRelease(kit: 8, runtime: 8), 8)
        XCTAssertNil(Toolchain.classRelease(kit: nil, runtime: 21))
    }

    func testAPatchIsTooNewOnlyForAnOlderJavaThatCouldRunAny() {
        XCTAssertTrue(Toolchain.isTooNew(release: 25, for: 21))
        XCTAssertFalse(Toolchain.isTooNew(release: 21, for: 25))
        XCTAssertFalse(Toolchain.isTooNew(release: 21, for: 21))
        XCTAssertFalse(Toolchain.isTooNew(release: nil, for: 21), "a marker from before it said")
        XCTAssertFalse(Toolchain.isTooNew(release: 25, for: nil), "a runtime not read")
        XCTAssertFalse(Toolchain.isTooNew(release: 8, for: 7), "no rebuild compiles below 8")
    }

    func testOnlyAJavaThatCannotBeHadOrDoesNotRunStepsDownToAnOlderOne() {
        XCTAssertTrue(Toolchain.stepsDown(after: JavaDownload.Trouble.noRelease(25), feature: 25))
        XCTAssertTrue(Toolchain.stepsDown(after: JavaDownload.Trouble.noJavaInside, feature: 25))
        XCTAssertTrue(Toolchain.stepsDown(after: JavaDownload.Trouble.unsupportedMachine, feature: 25))
        XCTAssertFalse(
            Toolchain.stepsDown(after: JavaDownload.Trouble.badChecksum(expected: "a", got: "b"), feature: 25)
        )
        XCTAssertFalse(Toolchain.stepsDown(after: URLError(.timedOut), feature: 25), "the network fails 21 too")
        XCTAssertFalse(Toolchain.stepsDown(after: DownloadError.badStatus(503), feature: 25), "a busy server")
        XCTAssertFalse(Toolchain.stepsDown(after: CocoaError(.fileWriteOutOfSpace), feature: 25))
    }
}
