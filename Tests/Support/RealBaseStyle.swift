import Foundation
import XCTest

@testable import kmap

/// The base style a build of this code materializes, for the tests that read mkgmap's
/// actual rule set: prepared in the test root from this machine's mkgmap.jar. Never the
/// copy a past build left in the home directory, which can be months older than the code
/// and fail a test that has nothing wrong with it.
enum RealBaseStyle {
    /// Prepares the style and answers where it is. Preparing again with nothing changed
    /// returns at once. Skips the test where this machine has no mkgmap.
    static func directory() async throws -> URL {
        let realJar = URL(
            fileURLWithPath: ("~/.kmap/tools/mkgmap/mkgmap.jar" as NSString).expandingTildeInPath
        )
        try XCTSkipUnless(FileManager.default.fileExists(atPath: realJar.path), "no mkgmap.jar on this machine")
        // Copied into the test root, read-only, so the toolchain finds it there.
        let jar = Paths.tools.appendingPathComponent("mkgmap/mkgmap.jar")
        Paths.ensure(jar.deletingLastPathComponent())
        if !FileManager.default.fileExists(atPath: jar.path) {
            try FileManager.default.copyItem(at: realJar, to: jar)
        }
        let settings = SettingsStore()
        let toolchain = Toolchain(settings: settings)
        try XCTSkipUnless(toolchain.findMkgmap() != nil, "mkgmap could not be probed")
        let catalog = StyleCatalog(settings: settings, toolchain: toolchain)
        let plain = try XCTUnwrap(catalog.style(id: "plain"))
        try await catalog.prepare(plain, log: Log(), runner: ProcessRunner())
        return StyleCatalog.baseStyleDirectory
    }

    /// The same, for a test that is not `async`.
    static func preparedDirectory() throws -> URL {
        try blocking { try await directory() }
    }
}
