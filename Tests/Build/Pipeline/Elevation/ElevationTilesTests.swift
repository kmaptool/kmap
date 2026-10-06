import XCTest

@testable import kmap

final class ElevationTilesTests: XCTestCase {
    /// Cells a killed conversion left half made go after an hour; tiles and fresh parts stay.
    func testHalfMadeElevationCellsGoAfterAnHour() throws {
        let cache = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kmap-hgt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        for name in ["N45E006.hgt", "N45E006.hgt.1a2b3c4d.part", "N45E007.hgt.5e6f7a8b.part", "notes.part"] {
            try Data().write(to: cache.appendingPathComponent(name))
        }
        let old = Date().addingTimeInterval(-7200)
        for name in ["N45E006.hgt", "N45E006.hgt.1a2b3c4d.part", "notes.part"] {
            try FileManager.default.setAttributes(
                [.modificationDate: old],
                ofItemAtPath: cache.appendingPathComponent(name).path
            )
        }
        BuildPipeline.removeAbandonedParts(in: cache)
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: cache.path)),
            ["N45E006.hgt", "N45E007.hgt.5e6f7a8b.part", "notes.part"]
        )
    }

    /// A sweep runs at most once an hour for a folder in a run of kmap.
    func testAFolderIsSweptAgainOnlyAfterAnHour() {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "kmap-swept-\(UUID().uuidString)"
        )
        var runs = 0
        let now = Date()
        SweptOnce.sweep(folder, now: now) { _ in runs += 1 }
        SweptOnce.sweep(folder, now: now.addingTimeInterval(60)) { _ in runs += 1 }
        XCTAssertEqual(runs, 1)
        SweptOnce.sweep(folder, now: now.addingTimeInterval(3700)) { _ in runs += 1 }
        XCTAssertEqual(runs, 2)
    }
}
