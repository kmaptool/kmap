import XCTest

@testable import kmap

/// The library lists what a build leaves: card files, and the BaseCamp folder beside them.
@MainActor
final class LibraryScanTests: XCTestCase {
    private var ctx: AppContext!
    private var root: URL!

    override func setUp() {
        MainActor.assumeIsolated {
            super.setUp()
            ctx = AppContext()
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("kmap-library-\(UUID().uuidString)", isDirectory: true)
            let settings = ctx.settings
            let output = settings.settings.outputDirectory
            settings.update { $0.outputDirectory = root.path }
            addTeardownBlock { @MainActor [root] in
                settings.update { $0.outputDirectory = output }
                if let root { try? FileManager.default.removeItem(at: root) }
            }
        }
    }

    private func drawn(_ screen: Screen) -> String {
        let surface = Surface()
        surface.resize(120, 30)
        surface.clear(ctx.theme.base)
        screen.tick(ctx)
        screen.render(into: surface, rect: Rect(x: 0, y: 0, w: 120, h: 30), ctx: ctx)
        return surface.asText()
    }

    func testABaseCampFolderIsListedBesideTheCardFile() async throws {
        let build = root.appendingPathComponent("2026-09-28_monaco", isDirectory: true)
        try FileManager.default.createDirectory(
            at: build.appendingPathComponent("kmap-monaco-2026-09-28.gmap/Product1", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("img".utf8).write(to: build.appendingPathComponent("kmap-monaco-2026-09-28.img"))
        try Data("notes".utf8).write(to: build.appendingPathComponent("build-info.txt"))

        let text = drawn(LibraryScreen())
        XCTAssertTrue(text.contains("2026-09-28_monaco/kmap-monaco-2026-09-28.img"), text)
        XCTAssertTrue(text.contains("2026-09-28_monaco/kmap-monaco-2026-09-28.gmap"), text)
        XCTAssertFalse(text.contains("build-info.txt"), "the manifest is not a map")
        XCTAssertFalse(text.contains("Product1"), "a folder is one map, not its parts")
    }
}
