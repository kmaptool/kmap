import XCTest
@testable import kmap

/// Folding Assets/ back into the source that carries them.
///
/// The generated file is committed, so a payload that could close its own delimiter ends
/// the literal early and breaks the build rather than the map.
final class AssetEmbedderTests: XCTestCase {

    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kmap-embed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for asset in AssetEmbedder.assets {
            let url = directory.appendingPathComponent(asset.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "payload of \(asset.property)\nsecond line\n"
                .write(to: url, atomically: true, encoding: .utf8)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testEveryAssetBecomesAProperty() throws {
        let made = try AssetEmbedder.render(from: directory)
        for asset in AssetEmbedder.assets {
            XCTAssertTrue(made.contains("static let \(asset.property) ="), asset.property)
            XCTAssertTrue(made.contains("payload of \(asset.property)"), asset.property)
        }
        XCTAssertTrue(made.contains("static let styleInfo ="))
        XCTAssertTrue(made.hasPrefix("import Foundation\n"))
        XCTAssertTrue(made.hasSuffix("}\n"))
    }

    /// The payload's trailing newline is part of the literal; the closing delimiter goes on
    /// the line after it.
    func testAPayloadKeepsItsTrailingNewline() throws {
        let made = try AssetEmbedder.render(from: directory)
        XCTAssertTrue(made.contains("second line\n\n\"\"\"#####"))
    }

    func testAMissingAssetIsNamed() throws {
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent(AssetEmbedder.assets[0].path))
        XCTAssertThrowsError(try AssetEmbedder.render(from: directory)) { error in
            XCTAssertTrue("\(error)".contains("missing asset"))
        }
    }

    /// A payload carrying the closing delimiter would end the literal early, leaving the
    /// rest to be read as Swift.
    func testAPayloadThatCouldCloseItsOwnLiteralIsRefused() throws {
        let url = directory.appendingPathComponent(AssetEmbedder.assets[0].path)
        try "before\n\"\"\"#####\nafter\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try AssetEmbedder.render(from: directory)) { error in
            XCTAssertTrue("\(error)".contains("cannot be embedded"))
        }
    }

    /// The committed source must match what rendering Assets/ produces.
    func testTheCommittedSourceMatchesTheAssetsItWasMadeFrom() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Style
            .deletingLastPathComponent()   // Build
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository
        let assets = root.appendingPathComponent("Assets")
        try XCTSkipUnless(FileTools.exists(assets), "not a working copy")
        let generated = try AssetEmbedder.render(from: assets)
        let committed = try String(
            contentsOf: root.appendingPathComponent("Sources/kmap/Build/Style/StyleAssets.swift"),
            encoding: .utf8)
        XCTAssertEqual(generated, committed,
                       "Assets/ and StyleAssets.swift disagree — run `make assets`")
    }
}
