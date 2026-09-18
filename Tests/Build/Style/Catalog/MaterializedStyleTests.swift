import XCTest
@testable import kmap

/// The base style materialized from the real stock style, where this machine has mkgmap.
/// The stock rules are mkgmap's and not in the repository, so everywhere else this skips;
/// here it is what notices that a new mkgmap moved a rule kmap anchors on.
final class MaterializedStyleTests: XCTestCase {

    private struct Prepared {
        let catalog: StyleCatalog
        let plain: MapStyle
        let log: Log
        let runner = ProcessRunner()
    }

    private func prepared() throws -> Prepared {
        // The real jar, read-only, copied into the test root so the toolchain finds it.
        let realJar = URL(fileURLWithPath: ("~/.kmap/tools/mkgmap/mkgmap.jar" as NSString)
            .expandingTildeInPath)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: realJar.path),
                          "no mkgmap.jar on this machine")
        let jar = Paths.tools.appendingPathComponent("mkgmap/mkgmap.jar")
        Paths.ensure(jar.deletingLastPathComponent())
        if !FileManager.default.fileExists(atPath: jar.path) {
            try FileManager.default.copyItem(at: realJar, to: jar)
        }
        let settings = SettingsStore()
        let toolchain = Toolchain(settings: settings)
        try XCTSkipUnless(toolchain.findMkgmap() != nil, "mkgmap could not be probed")
        let catalog = StyleCatalog(settings: settings, toolchain: toolchain)
        return Prepared(catalog: catalog, plain: try XCTUnwrap(catalog.style(id: "plain")),
                        log: Log(showing: .info))
    }

    private func ruleFiles() throws -> [String: String] {
        var out: [String: String] = [:]
        for name in ["points", "lines", "polygons", "relations"] {
            out[name] = try String(
                contentsOf: StyleCatalog.baseStyleDirectory.appendingPathComponent(name), encoding: .utf8)
        }
        return out
    }

    func testEveryAnchoredPassFindsItsStockRule() async throws {
        let it = try prepared()
        try await it.catalog.prepare(it.plain, log: it.log, runner: it.runner, cyrillicLabels: true)
        let complaints = it.log.snapshot().filter { $0.severity == .warn }.map(\.text)
        XCTAssertTrue(complaints.isEmpty, "this mkgmap's stock style has moved: \(complaints)")
    }

    func testTheRealStyleCarriesEveryBlockOnceAndNoTypeAfterFinalize() async throws {
        let it = try prepared()
        try await it.catalog.prepare(it.plain, log: it.log, runner: it.runner)
        for (name, text) in try ruleFiles() {
            let lines = text.components(separatedBy: "\n")
            let blocks = lines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("# --- kmap:") }
            XCTAssertEqual(blocks.count, Set(blocks).count, "\(name) carries a block twice")
            guard let finalize = lines.firstIndex(of: "<finalize>") else { continue }
            for line in lines[(finalize + 1)...] where !line.hasPrefix("#") {
                XCTAssertFalse(line.contains("[0x"), "\(name) defines a type after <finalize>: \(line)")
            }
        }
    }

    func testPreparingAgainWithTheSameChoicesChangesNothing() async throws {
        let it = try prepared()
        try await it.catalog.prepare(it.plain, log: it.log, runner: it.runner)
        let once = try ruleFiles()
        try await it.catalog.prepare(it.plain, log: it.log, runner: it.runner)
        XCTAssertEqual(try ruleFiles(), once)
    }

    func testTheAlphabetOfTheLabelsFollowsTheChoice() async throws {
        let it = try prepared()
        let cyrillic: (String) -> Bool = { $0.unicodeScalars.contains { (0x400...0x4FF).contains($0.value) } }
        try await it.catalog.prepare(it.plain, log: it.log, runner: it.runner, cyrillicLabels: false)
        XCTAssertFalse(cyrillic(try XCTUnwrap(try ruleFiles()["points"])),
                       "a Latin build must not carry Russian labels")
        try await it.catalog.prepare(it.plain, log: it.log, runner: it.runner, cyrillicLabels: true)
        XCTAssertTrue(cyrillic(try XCTUnwrap(try ruleFiles()["points"])))
    }
}
