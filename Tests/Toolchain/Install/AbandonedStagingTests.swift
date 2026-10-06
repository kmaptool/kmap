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
            "OpenJDK25U-jdk_x64_linux_hotspot_25_36.tar.gz", "mkgmap.new", "jdk", "mkgmap", "sea-latest.zip",
            "venv"
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

    /// An install killed between setting the earlier tool aside and moving the new one in
    /// leaves the earlier one to come back; one killed after leaves it to go.
    func testATwoStepSwapCutInTheMiddleIsSettled() throws {
        let tools = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "kmap-tools-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: tools) }
        let mkgmap = tools.appendingPathComponent("mkgmap", isDirectory: true)
        try FileManager.default.createDirectory(at: mkgmap, withIntermediateDirectories: true)
        try Data("patched".utf8).write(to: mkgmap.appendingPathComponent("mkgmap-patched.jar.old"))
        try Data("new".utf8).write(to: mkgmap.appendingPathComponent("mkgmap-patched.jar"))
        let jdk = tools.appendingPathComponent("jdk.old", isDirectory: true)
        try FileManager.default.createDirectory(at: jdk, withIntermediateDirectories: true)
        try Data().write(to: jdk.appendingPathComponent("release"))

        Toolchain.settleInterruptedSwaps(in: tools)

        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: tools.path)), ["jdk", "mkgmap"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: tools.appendingPathComponent("jdk/release").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: mkgmap.path), ["mkgmap-patched.jar"])
        XCTAssertEqual(try Data(contentsOf: mkgmap.appendingPathComponent("mkgmap-patched.jar")), Data("new".utf8))
    }

    /// The sweep an install starts with settles a swap cut short too.
    func testTheSweepPutsBackAToolSetAside() throws {
        let tools = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "kmap-tools-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: tools) }
        try FileManager.default.createDirectory(
            at: tools.appendingPathComponent("jdk.old"),
            withIntermediateDirectories: true
        )
        Toolchain.removeAbandonedStaging(in: tools, now: Date())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tools.path), ["jdk"])
    }
}
