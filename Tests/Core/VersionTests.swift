import XCTest
@testable import kmap

/// What this build calls itself, and whether it talks about its own timings.
final class VersionTests: XCTestCase {

    func testTheVersionIsThreeNumbersAndNothingElse() {
        // Printed by `kmap --version`; anything beyond x.y.z has to be interpreted.
        let parts = Version.number.split(separator: ".")
        XCTAssertEqual(parts.count, 3, Version.number)
        for part in parts {
            XCTAssertNotNil(Int(part), Version.number)
        }
    }

    func testTheGeneratedNumberMatchesTheVersionFile() throws {
        // The number lives in the VERSION file; `make version` folds it into
        // VersionNumber.swift. This catches an edited VERSION that was never folded.
        let file = URL(fileURLWithPath: #filePath)   // Tests/Core/VersionTests.swift
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("VERSION")
        let held = try String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(held, Version.number,
                       "run `make version` — VersionNumber.swift is behind the VERSION file")
    }

    func testTheLineNamesTheProgramAsWellAsTheNumber() {
        XCTAssertEqual(Version.line, "kmap \(Version.number)")
        XCTAssertTrue(Version.full.hasPrefix(Version.line), Version.full)
    }

    func testADebugBuildSaysSoBecauseItsTimingsMeanSomethingElse() {
        // A debug build's timings are several times slower; the suite itself is one.
        XCTAssertTrue(Version.full.contains("(debug)"), Version.full)
        XCTAssertTrue(Measured.reported)
    }

    func testATimingLineIsOnlyWrittenForWorkThatCostSomething() {
        XCTAssertNil(Measured.line("instant", since: Date()))
        let line = try? XCTUnwrap(Measured.line("traced the contours",
                                                since: Date().addingTimeInterval(-3)))
        XCTAssertTrue(line?.contains("traced the contours") ?? false, line ?? "nothing")
        XCTAssertTrue(line?.contains("3.0 s") ?? false, line ?? "nothing")
        // The caller may ask for a lower bar than the default.
        XCTAssertNotNil(Measured.line("quick", since: Date().addingTimeInterval(-0.05),
                                      atLeast: 0.01))
    }

    func testTheMemoryReadingIsARealNumberOfBytes() {
        // Zero would read as a build that costs nothing.
        XCTAssertGreaterThan(Machine.memoryInUse(), 1_000_000)
    }
}

/// Facts about the repository's own layout.
final class PackageLayoutTests: XCTestCase {

    private var sources: URL {
        URL(fileURLWithPath: #filePath)          // Tests/Core/VersionTests.swift
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/kmap")
    }

    /// The asset generator must aim at the path the assets live at; a second copy at a
    /// stale path makes SwiftPM refuse the build with "multiple producers".
    func testTheAssetGeneratorWritesWhereTheAssetsActuallyLive() {
        XCTAssertEqual(AssetEmbedder.defaultOutput, "Sources/kmap/Build/Style/StyleAssets.swift")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sources.appendingPathComponent("Build/Style/StyleAssets.swift").path))
    }
}
