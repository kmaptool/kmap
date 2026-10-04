import XCTest

@testable import kmap

/// The JVM's cache for mkgmap: offered only to a Java that knows the options, recorded
/// once, and named so that a new jar or a new Java never reads an old one.
final class JavaWarmStartTests: XCTestCase {
    private var folder: URL!
    private var jar: URL { folder.appendingPathComponent("mkgmap-patched.jar") }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("warm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileTools.write(Data("jar".utf8), to: jar)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
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
        let plan = JavaWarmStart.plan(java: java(#"openjdk version "21.0.4""#), jar: jar, heapGB: 8, recording: true)
        XCTAssertEqual(plan, JavaWarmStart.Plan())
        XCTAssertEqual(
            JavaWarmStart.plan(java: java("unknown"), jar: jar, heapGB: 8, recording: true),
            JavaWarmStart.Plan()
        )
    }

    func testTheFirstCompileRecordsAndTheNextReads() throws {
        let runtime = java(#"openjdk version "25.0.1""#)
        let first = JavaWarmStart.plan(java: runtime, jar: jar, heapGB: 8, recording: true)
        let recording = try XCTUnwrap(first.recording), cache = try XCTUnwrap(first.cache)
        XCTAssertTrue(first.options.contains("-XX:AOTMode=record"))
        XCTAssertTrue(first.options.contains("-XX:AOTConfiguration=\(recording.path)"))
        XCTAssertFalse(first.options.contains { $0.hasPrefix("-XX:AOTCache=") })

        // A short run beside the compile reads a cache and never records one.
        XCTAssertEqual(
            JavaWarmStart.plan(java: runtime, jar: jar, heapGB: 8, recording: false),
            JavaWarmStart.Plan()
        )

        let pending = cache.appendingPathExtension("new")
        let assembly = try XCTUnwrap(JavaWarmStart.assembly(first, jar: jar, pending: pending))
        XCTAssertTrue(assembly.contains("-XX:AOTMode=create"))
        XCTAssertTrue(assembly.contains("-XX:AOTCache=\(pending.path)"))
        XCTAssertEqual(Array(assembly.suffix(2)), ["-cp", jar.path])

        try FileTools.write(Data("cache".utf8), to: cache)
        let next = JavaWarmStart.plan(java: runtime, jar: jar, heapGB: 8, recording: true)
        XCTAssertNil(next.recording)
        XCTAssertTrue(next.options.contains("-XX:AOTCache=\(cache.path)"))
        XCTAssertEqual(JavaWarmStart.plan(java: runtime, jar: jar, heapGB: 8, recording: false), next)
    }

    func testANewJarANewJavaOrAnotherHeapNamesANewCache() throws {
        let runtime = java(#"openjdk version "25.0.1""#)
        let name = JavaWarmStart.cacheFile(java: runtime, jar: jar, heapGB: 8)
        XCTAssertEqual(name, JavaWarmStart.cacheFile(java: runtime, jar: jar, heapGB: 8))
        XCTAssertNotEqual(name, JavaWarmStart.cacheFile(java: runtime, jar: jar, heapGB: 2))
        XCTAssertNotEqual(name, JavaWarmStart.cacheFile(java: runtime, jar: jar, heapGB: 40))
        XCTAssertNotEqual(name, JavaWarmStart.cacheFile(java: java(#"openjdk version "26""#), jar: jar, heapGB: 8))
        try FileTools.write(Data("a rebuilt jar".utf8), to: jar)
        XCTAssertNotEqual(name, JavaWarmStart.cacheFile(java: runtime, jar: jar, heapGB: 8))
    }

    func testLeftoversAreTheOtherCachesAndRecordingsOnly() throws {
        let keep = folder.appendingPathComponent("warm-1111.aot")
        for name in ["warm-1111.aot", "warm-2222.aot", "warm-2222.aotconf", "warm-3333.aot.new", "mkgmap.jar"] {
            try FileTools.write(Data(), to: folder.appendingPathComponent(name))
        }
        let found = JavaWarmStart.leftovers(beside: jar, keeping: keep).map(\.lastPathComponent).sorted()
        XCTAssertEqual(found, ["warm-2222.aot", "warm-2222.aotconf", "warm-3333.aot.new"])
    }

    func testTheRecordingJVMsOwnLineIsNotMkgmaps() {
        XCTAssertTrue(JavaWarmStart.isOwnRemark(" AOTConfiguration recorded: /tmp/warm.aotconf"))
        XCTAssertFalse(JavaWarmStart.isOwnRemark("SEVERE (MapSplitter): RGN section too big"))
    }
}
