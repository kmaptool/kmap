import XCTest
@testable import kmap

/// Uncommitted byte-compare harness. Materializes the base style twice (bare and with
/// every option on) plus the shipped palette TYPs into $KMAP_HARNESS_OUT, so a refactor
/// can be diffed before/after. Skipped unless the variable is set.
final class ZZMaterializeHarness: XCTestCase {
    func testDumpMaterializedStyle() async throws {
        guard let outPath = ProcessInfo.processInfo.environment["KMAP_HARNESS_OUT"],
              !outPath.isEmpty else {
            throw XCTSkip("KMAP_HARNESS_OUT not set")
        }
        let out = URL(fileURLWithPath: outPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        // The real jar, read-only, copied into the test root so the toolchain finds it.
        let realJar = URL(fileURLWithPath: ("~/.kmap/tools/mkgmap/mkgmap.jar" as NSString)
            .expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: realJar.path) else {
            throw XCTSkip("no mkgmap.jar at ~/.kmap/tools/mkgmap")
        }
        let jarDest = Paths.tools.appendingPathComponent("mkgmap/mkgmap.jar")
        Paths.ensure(jarDest.deletingLastPathComponent())
        if !FileManager.default.fileExists(atPath: jarDest.path) {
            try FileManager.default.copyItem(at: realJar, to: jarDest)
        }

        let settings = SettingsStore()
        let toolchain = Toolchain(settings: settings)
        guard toolchain.findMkgmap() != nil else {
            throw XCTSkip("mkgmap not probed (java missing?)")
        }
        let catalog = StyleCatalog(settings: settings, toolchain: toolchain)
        let log = Log(showing: .error)
        let runner = ProcessRunner()
        guard let plain = catalog.style(id: "plain") else {
            XCTFail("no plain style"); return
        }

        func snapshot(_ name: String) throws {
            let dest = out.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: StyleCatalog.baseStyleDirectory, to: dest)
        }

        // Bare.
        try await catalog.prepare(plain, log: log, runner: runner)
        try snapshot("base-plain")

        // Everything on: descriptions, hides, a zoom window, cyrillic labels.
        var plan = ZoomPlan(id: "harness", name: "harness", levelsID: LevelsProfile.smooth.id)
        plan.windows["trails"] = ZoomPlan.Window(finest: 0, coarsest: 2)
        plan.windows["woodland"] = ZoomPlan.Window(finest: 1, coarsest: 3)
        try await catalog.prepare(
            plain, log: log, runner: runner,
            descriptions: .inName,
            hidden: ["power-tower", "man_made-survey_point", "barriers-fence"],
            zoom: (plan, .smooth),
            cyrillicLabels: true)
        try snapshot("base-full")

        // Shipped palettes: the generated TYP sources.
        for id in ["osm-carto", "opentopomap"] {
            guard let style = catalog.style(id: id) else { XCTFail("no \(id)"); return }
            try await catalog.prepare(style, log: log, runner: runner)
            guard let shipped = StyleCatalog.shippedPalette(id: id) else { continue }
            let typ = StyleCatalog.shippedTypURL(of: shipped)
            let dest = out.appendingPathComponent(typ.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: typ, to: dest)
        }
    }
}
