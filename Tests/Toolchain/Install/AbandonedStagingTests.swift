import XCTest

@testable import kmap

final class AbandonedStagingTests: XCTestCase {
    func testWhatAKilledInstallLeftGoesAndNothingElse() throws {
        let tools = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "kmap-tools-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: tools) }
        let names = [
            "jdk-unpack-1a2b3c4d", "unpack-1a2b3c4d", "mkgmap-patch-1a2b3c4d",
            "OpenJDK25U-jdk_x64_linux_hotspot_25_36.tar.gz", "jdk", "mkgmap", "sea-latest.zip", "venv"
        ]
        for name in names {
            try FileManager.default.createDirectory(
                at: tools.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }
        // Too fresh: another kmap may be installing right now.
        Toolchain.removeAbandonedStaging(in: tools, now: Date())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tools.path).count, names.count)

        Toolchain.removeAbandonedStaging(in: tools, now: Date().addingTimeInterval(7200))
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: tools.path)),
            ["jdk", "mkgmap", "sea-latest.zip", "venv"]
        )
    }
}
