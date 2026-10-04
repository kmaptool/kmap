import XCTest

@testable import kmap

/// The JVM's cache for mkgmap: offered only to a Java that knows the options, recorded
/// once, and named so that a new jar or a new Java never reads an old one.
final class JavaWarmStartTests: XCTestCase {
    private var folder: URL!
    private var jar: URL { folder.appendingPathComponent("mkgmap-patched.jar") }
    /// Where the caches go here, as kmap's own folder does in a build.
    private var caches: URL { folder.appendingPathComponent("warm-start", isDirectory: true) }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("warm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileTools.write(Data("jar".utf8), to: jar)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A link, or the test skipped where this process may not make one, as a Windows
    /// task without the right.
    private func makeLink(_ link: URL, to target: URL) throws {
        do {
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        } catch {
            throw XCTSkip("this machine does not let a test make links: \(error)")
        }
    }

    private func java(_ version: String) -> JavaRuntime {
        JavaRuntime(path: "/usr/bin/java", version: version, options: [])
    }

    func testTheFeatureReleaseIsReadFromTheVersionLine() {
        XCTAssertEqual(java(#"openjdk version "27" 2026-09-15"#).major, 27)
        XCTAssertEqual(java(#"openjdk version "21.0.4" 2024-07-16 LTS"#).major, 21)
        XCTAssertEqual(java(#"java version "1.8.0_292""#).major, 8)
        XCTAssertEqual(java(#"openjdk version "25-ea" 2025-09-16"#).major, 25)
        XCTAssertNil(java("unknown").major)
    }

    func testAnOlderJavaIsGivenNoOptionItWouldRefuse() {
        let older = java(#"openjdk version "21.0.4""#)
        let plan = JavaWarmStart.plan(java: older, jar: jar, heapGB: 8, recording: true, in: caches)
        XCTAssertEqual(plan, JavaWarmStart.Plan())
        XCTAssertEqual(
            JavaWarmStart.plan(java: java("unknown"), jar: jar, heapGB: 8, recording: true, in: caches),
            JavaWarmStart.Plan()
        )
    }

    func testTheFirstCompileRecordsAndTheNextReads() throws {
        let runtime = java(#"openjdk version "25.0.1""#)
        let first = JavaWarmStart.plan(java: runtime, jar: jar, heapGB: 8, recording: true, in: caches)
        let recording = try XCTUnwrap(first.recording), cache = try XCTUnwrap(first.cache)
        XCTAssertTrue(first.options.contains("-XX:AOTMode=record"))
        XCTAssertTrue(first.options.contains("-XX:AOTConfiguration=\(recording.path)"))
        XCTAssertFalse(first.options.contains { $0.hasPrefix("-XX:AOTCache=") })

        // A short run beside the compile reads a cache and never records one.
        let beside = JavaWarmStart.plan(java: runtime, jar: jar, heapGB: 8, recording: false, in: caches)
        XCTAssertTrue(beside.options.isEmpty)
        XCTAssertNil(beside.recording)

        let pending = JavaWarmStart.pending(for: recording)
        let assembly = try XCTUnwrap(JavaWarmStart.assembly(first, jar: jar, heapGB: 8))
        XCTAssertTrue(assembly.contains("-XX:AOTMode=create"))
        XCTAssertTrue(assembly.contains("-XX:AOTCache=\(pending.path)"))
        XCTAssertEqual(Array(assembly.suffix(2)), ["-cp", jar.path])
        // Under the heap the compile ran with: a cache made under another is refused
        // once the 2 lay objects out differently.
        XCTAssertTrue(assembly.contains("-Xmx8g"))
        XCTAssertTrue(try XCTUnwrap(JavaWarmStart.assembly(first, jar: jar, heapGB: 40)).contains("-Xmx40g"))

        try FileTools.write(Data("cache".utf8), to: cache)
        let next = JavaWarmStart.plan(java: runtime, jar: jar, heapGB: 8, recording: true, in: caches)
        XCTAssertNil(next.recording)
        XCTAssertTrue(next.options.contains("-XX:AOTCache=\(cache.path)"))
        XCTAssertEqual(JavaWarmStart.plan(java: runtime, jar: jar, heapGB: 8, recording: false, in: caches), next)
    }

    func testTwoBuildsRecordingAtOnceWriteFilesOfTheirOwn() throws {
        let runtime = java(#"openjdk version "25.0.1""#)
        let one = JavaWarmStart.plan(java: runtime, jar: jar, heapGB: 8, recording: true, in: caches)
        let other = JavaWarmStart.plan(java: runtime, jar: jar, heapGB: 8, recording: true, in: caches)
        XCTAssertEqual(one.cache, other.cache, "the same cache in the end")
        XCTAssertNotEqual(one.recording, other.recording)
        XCTAssertNotEqual(
            JavaWarmStart.pending(for: try XCTUnwrap(one.recording)),
            JavaWarmStart.pending(for: try XCTUnwrap(other.recording))
        )
    }

    func testANewJarANewJavaOrAnotherHeapNamesANewCache() throws {
        let runtime = java(#"openjdk version "25.0.1""#)
        let name = JavaWarmStart.cacheFile(java: runtime, jar: jar, heapGB: 8, in: caches)
        XCTAssertEqual(name, JavaWarmStart.cacheFile(java: runtime, jar: jar, heapGB: 8, in: caches))
        XCTAssertNotEqual(name, JavaWarmStart.cacheFile(java: runtime, jar: jar, heapGB: 2, in: caches))
        XCTAssertNotEqual(name, JavaWarmStart.cacheFile(java: runtime, jar: jar, heapGB: 40, in: caches))
        let newer = java(#"openjdk version "26""#)
        XCTAssertNotEqual(name, JavaWarmStart.cacheFile(java: newer, jar: jar, heapGB: 8, in: caches))
        try FileTools.write(Data("a rebuilt jar".utf8), to: jar)
        XCTAssertNotEqual(name, JavaWarmStart.cacheFile(java: runtime, jar: jar, heapGB: 8, in: caches))
    }

    func testLeftoversAreTheOtherCachesAndRecordingsGoneStale() throws {
        Paths.ensure(caches)
        let keep = caches.appendingPathComponent("warm-1111.aot")
        for name in ["warm-1111.aot", "warm-2222.aot", "warm-2222-ab12.aotconf", "warm-3333-cd34.new", "notes.txt"] {
            try FileTools.write(Data(), to: caches.appendingPathComponent(name))
        }
        // Written a moment ago: they may be another build's, still in the making.
        XCTAssertEqual(JavaWarmStart.leftovers(keeping: keep, in: caches), [])
        let later = Date().addingTimeInterval(JavaWarmStart.staleAfter + 60)
        let found = JavaWarmStart.leftovers(keeping: keep, in: caches, now: later).map(\.lastPathComponent).sorted()
        XCTAssertEqual(found, ["warm-2222-ab12.aotconf", "warm-2222.aot", "warm-3333-cd34.new"])
    }

    func testReadingACacheCountsAsUsingIt() throws {
        // Staleness counts from the last read, not from when the cache was made.
        let runtime = java(#"openjdk version "25.0.1""#)
        let cache = JavaWarmStart.cacheFile(java: runtime, jar: jar, heapGB: 8, in: caches)
        Paths.ensure(caches)
        try FileTools.write(Data("cache".utf8), to: cache)
        let old = Date().addingTimeInterval(-2 * JavaWarmStart.staleAfter)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: cache.path)
        _ = JavaWarmStart.plan(java: runtime, jar: jar, heapGB: 8, recording: false, in: caches)
        let touched = try XCTUnwrap(FileTools.modified(of: cache))
        XCTAssertGreaterThan(touched, Date().addingTimeInterval(-60))
    }

    func testAReplacedJarTakesItsOwnCachesWithItAndNoOthers() throws {
        let runtime = java(#"openjdk version "25.0.1""#)
        let other = folder.appendingPathComponent("elsewhere/mkgmap.jar")
        Paths.ensure(other.deletingLastPathComponent())
        try FileTools.write(Data("other".utf8), to: other)
        let mine = try XCTUnwrap(
            JavaWarmStart.plan(java: runtime, jar: jar, heapGB: 8, recording: true, in: caches).recording
        )
        let theirs = JavaWarmStart.cacheFile(java: runtime, jar: other, heapGB: 8, in: caches)
        for file in [mine, JavaWarmStart.pending(for: mine), theirs] { try FileTools.write(Data(), to: file) }
        try FileTools.write(Data(), to: caches.appendingPathComponent("warm.txt"))
        JavaWarmStart.forgetAll(for: jar, in: caches)
        let left = FileTools.contents(of: caches).map(\.lastPathComponent).sorted()
        XCTAssertEqual(left, [theirs.lastPathComponent, "warm.txt"].sorted())
    }

    func testTheCachesStayInKmapsFolderWhereverTheJarIs() {
        // A jar the user pointed at may sit where kmap cannot write.
        let runtime = java(#"openjdk version "25.0.1""#)
        let shared = URL(fileURLWithPath: "/usr/share/mkgmap/mkgmap.jar")
        let plan = JavaWarmStart.plan(java: runtime, jar: shared, heapGB: 8, recording: true)
        XCTAssertEqual(
            plan.cache?.deletingLastPathComponent().standardizedFileURL,
            JavaWarmStart.directory.standardizedFileURL
        )
        XCTAssertEqual(
            plan.recording?.deletingLastPathComponent().standardizedFileURL,
            JavaWarmStart.directory.standardizedFileURL
        )
        JavaWarmStart.discard(plan)
    }

    func testTheJVMsOptionsAndTheJarsPathNameTheCacheToo() throws {
        let plain = java(#"openjdk version "25.0.1""#)
        let rescued = JavaRuntime(
            path: plain.path,
            version: plain.version,
            options: ["-XX:-UseCompressedClassPointers"]
        )
        let name = JavaWarmStart.cacheFile(java: plain, jar: jar, heapGB: 8, in: caches)
        XCTAssertNotEqual(name, JavaWarmStart.cacheFile(java: rescued, jar: jar, heapGB: 8, in: caches))
        let copy = folder.appendingPathComponent("copy/mkgmap-patched.jar")
        Paths.ensure(copy.deletingLastPathComponent())
        try FileManager.default.copyItem(at: jar, to: copy)
        try FileManager.default.setAttributes(
            [.modificationDate: try XCTUnwrap(FileTools.modified(of: jar))],
            ofItemAtPath: copy.path
        )
        XCTAssertNotEqual(name, JavaWarmStart.cacheFile(java: plain, jar: copy, heapGB: 8, in: caches))
    }

    func testOpenJ9IsGivenNoHotSpotOption() {
        var j9 = java(#"openjdk version "25.0.1""#)
        j9.isOpenJ9 = true
        XCTAssertEqual(
            JavaWarmStart.plan(java: j9, jar: jar, heapGB: 8, recording: true, in: caches),
            JavaWarmStart.Plan()
        )
    }

    func testAJVMThatFailedToRecordIsNotAskedAgainUntilTheMarkGoesStale() throws {
        let runtime = java(#"openjdk version "25.0.1""#)
        let first = JavaWarmStart.plan(java: runtime, jar: jar, heapGB: 8, recording: true, in: caches)
        XCTAssertNotNil(first.recording)
        JavaWarmStart.refuse(first)
        let next = JavaWarmStart.plan(java: runtime, jar: jar, heapGB: 8, recording: true, in: caches)
        XCTAssertTrue(next.options.isEmpty, "a cold compile")
        XCTAssertNil(next.recording)
        let later = Date().addingTimeInterval(JavaWarmStart.staleAfter + 60)
        let mark = JavaWarmStart.refusal(of: try XCTUnwrap(first.cache))
        let stale = JavaWarmStart.leftovers(keeping: first.cache, in: caches, now: later).map(\.lastPathComponent)
        XCTAssertTrue(stale.contains(mark.lastPathComponent), "\(stale)")
        // Not yet cleared away, a stale mark no longer holds the recording back.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-JavaWarmStart.staleAfter - 60)],
            ofItemAtPath: mark.path
        )
        let again = JavaWarmStart.plan(java: runtime, jar: jar, heapGB: 8, recording: true, in: caches)
        XCTAssertNotNil(again.recording)
    }

    func testAJVMRebuiltUnderTheSameNameAndVersionGetsACacheOfItsOwn() throws {
        // Named through a link, as Homebrew's is: the file it leads to is what changes.
        let binary = folder.appendingPathComponent("java-25.0.1")
        try FileTools.write(Data("jvm".utf8), to: binary)
        let link = folder.appendingPathComponent("java")
        try makeLink(link, to: binary)
        let runtime = JavaRuntime(path: link.path, version: #"openjdk version "25.0.1""#, options: [])
        let before = JavaWarmStart.cacheFile(java: runtime, jar: jar, heapGB: 8, in: caches)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)],
            ofItemAtPath: binary.path
        )
        XCTAssertNotEqual(JavaWarmStart.cacheFile(java: runtime, jar: jar, heapGB: 8, in: caches), before)
    }

    func testAJarReplacedBehindALinkGetsACacheOfItsOwn() throws {
        let linked = folder.appendingPathComponent("mkgmap-link.jar")
        try makeLink(linked, to: jar)
        let runtime = java(#"openjdk version "25.0.1""#)
        let before = JavaWarmStart.cacheFile(java: runtime, jar: linked, heapGB: 8, in: caches)
        try FileTools.write(Data("a newer mkgmap".utf8), to: jar)
        XCTAssertNotEqual(JavaWarmStart.cacheFile(java: runtime, jar: linked, heapGB: 8, in: caches), before)
    }

    func testOnlyMkgmapsLastLineWithNoFailureCountsAsAFinish() {
        XCTAssertTrue(BuildPipeline.isCleanFinish("Number of ExitExceptions: 0"))
        XCTAssertTrue(BuildPipeline.isCleanFinish("Number of ExitExceptions: 0\r"))
        XCTAssertFalse(BuildPipeline.isCleanFinish("Number of ExitExceptions: 1"))
        XCTAssertFalse(BuildPipeline.isCleanFinish("Number of ExitExceptions: 10"))
        XCTAssertFalse(BuildPipeline.isCleanFinish("Number of MapFailedExceptions: 0"))
    }

    func testAProbeRecordsAsTheCompileWouldIntoAFileOfItsOwn() throws {
        let plan = JavaWarmStart.plan(
            java: java(#"openjdk version "25.0.1""#),
            jar: jar,
            heapGB: 8,
            recording: true,
            in: caches
        )
        let recording = try XCTUnwrap(plan.recording)
        let probe = try XCTUnwrap(JavaWarmStart.probe(plan, jar: jar, heapGB: 8))
        XCTAssertNotEqual(probe.recording, recording)
        XCTAssertTrue(probe.options.contains("-XX:AOTMode=record"))
        XCTAssertTrue(probe.options.contains("-XX:AOTConfiguration=\(probe.recording.path)"))
        XCTAssertFalse(probe.options.contains("-XX:AOTConfiguration=\(recording.path)"))
        XCTAssertEqual(Array(probe.options.suffix(4)), ["-Xmx8g", "-jar", jar.path, "--version"])
        XCTAssertNil(
            JavaWarmStart.probe(JavaWarmStart.Plan(), jar: jar, heapGB: 8),
            "nothing to probe when not recording"
        )
    }

    func testARecordingGoesStaleSoonerThanACache() throws {
        // A JVM writes its recording only as it exits: an hour-old one belongs to no run.
        Paths.ensure(caches)
        for name in ["warm-a-1111.aotconf", "warm-a-1111.new", "warm-b.aot", "warm-b.refused"] {
            try FileTools.write(Data(), to: caches.appendingPathComponent(name))
        }
        let hours2 = Date().addingTimeInterval(2 * JavaWarmStart.recordingStaleAfter)
        let found = JavaWarmStart.leftovers(keeping: nil, in: caches, now: hours2).map(\.lastPathComponent).sorted()
        XCTAssertEqual(found, ["warm-a-1111.aotconf", "warm-a-1111.new"])
    }

    func testACacheMadeMeanwhileIsReadDespiteARefusal() throws {
        // Another build recorded under the same key after this machine's JVM refused once.
        let runtime = java(#"openjdk version "25.0.1""#)
        let first = JavaWarmStart.plan(java: runtime, jar: jar, heapGB: 8, recording: true, in: caches)
        JavaWarmStart.refuse(first)
        try FileTools.write(Data("cache".utf8), to: try XCTUnwrap(first.cache))
        let next = JavaWarmStart.plan(java: runtime, jar: jar, heapGB: 8, recording: true, in: caches)
        XCTAssertTrue(next.options.contains("-XX:AOTCache=\(try XCTUnwrap(first.cache).path)"))
    }

    func testTheJVMsOptionsFromTheEnvironmentNameTheCacheWhateverTheirCase() {
        let runtime = java(#"openjdk version "25.0.1""#)
        func name(_ environment: [String: String]) -> String {
            JavaWarmStart.cacheFile(java: runtime, jar: jar, heapGB: 8, in: caches, environment: environment)
                .lastPathComponent
        }
        let plain = name([:])
        XCTAssertNotEqual(plain, name(["JAVA_TOOL_OPTIONS": "-XX:+UseZGC"]))
        XCTAssertEqual(name(["JAVA_TOOL_OPTIONS": "-XX:+UseZGC"]), name(["Java_Tool_Options": "-XX:+UseZGC"]))
        XCTAssertEqual(plain, name(["PATH": "/usr/bin"]), "other variables change nothing")
    }

    func testDiscardTakesTheRecordingAndWhatWasMadeFromIt() throws {
        let plan = JavaWarmStart.plan(
            java: java(#"openjdk version "25.0.1""#),
            jar: jar,
            heapGB: 8,
            recording: true,
            in: caches
        )
        let recording = try XCTUnwrap(plan.recording)
        try FileTools.write(Data(), to: recording)
        try FileTools.write(Data(), to: JavaWarmStart.pending(for: recording))
        JavaWarmStart.discard(plan)
        XCTAssertFalse(FileTools.exists(recording))
        XCTAssertFalse(FileTools.exists(JavaWarmStart.pending(for: recording)))
    }

    func testTheVersionLineIsTheOneWithTheQuotedNumber() {
        // WSL1's rescue option is deprecated in Java 25, and the JVM says so first.
        let output = """
            OpenJDK 64-Bit Server VM warning: Option UseCompressedClassPointers was deprecated in version 25.0 and will likely be removed in a future release.
            openjdk version "25.0.1" 2025-10-21 LTS
            OpenJDK Runtime Environment Temurin-25.0.1+8 (build 25.0.1+8-LTS)
            """
        XCTAssertEqual(Toolchain.versionLine(of: output), #"openjdk version "25.0.1" 2025-10-21 LTS"#)
        XCTAssertEqual(java(Toolchain.versionLine(of: output)).major, 25)
        XCTAssertEqual(
            Toolchain.versionLine(of: "Picked up _JAVA_OPTIONS: -Xss4m\njava version \"21.0.4\" 2024-07-16 LTS"),
            #"java version "21.0.4" 2024-07-16 LTS"#
        )
        XCTAssertEqual(Toolchain.versionLine(of: "nothing here"), "unknown")
        // Windows ends its lines with CR LF.
        XCTAssertEqual(
            Toolchain.versionLine(
                of: "Picked up JAVA_TOOL_OPTIONS: -Dx=\"y\"\r\nopenjdk version \"25\" 2025-09-16\r\n"
            ),
            #"openjdk version "25" 2025-09-16"#,
            "a quote in an option line comes first: the version line must still be found"
        )
        XCTAssertEqual(
            java(Toolchain.versionLine(of: "Picked up JAVA_TOOL_OPTIONS: -Dx=\"y\"\r\nopenjdk version \"25\"\r\n"))
                .major,
            25
        )
        // A JVM that cannot load names no version.
        XCTAssertEqual(Toolchain.versionLine(of: "java: version 'GLIBC_2.34' not found"), "unknown")
    }

    func testTheRecordingJVMsOwnLineIsNotMkgmaps() {
        XCTAssertTrue(JavaWarmStart.isOwnRemark(" AOTConfiguration recorded: /tmp/warm.aotconf"))
        XCTAssertFalse(JavaWarmStart.isOwnRemark("SEVERE (MapSplitter): RGN section too big"))
    }
}
