import Foundation
import XCTest

@testable import kmap

/// Prepared in the test root from this machine's mkgmap.jar, never the style a past build
/// left in the home directory, which can be months older than the code and fail a sound
/// test.
enum RealBaseStyle {
    /// Returns at once when nothing changed. Skips the test where there is no mkgmap.
    static func directory() async throws -> URL {
        try RealMkgmap.install()
        let settings = SettingsStore()
        let toolchain = Toolchain(settings: settings)
        let catalog = StyleCatalog(settings: settings, toolchain: toolchain)
        let plain = try XCTUnwrap(catalog.style(id: "plain"))
        try await catalog.prepare(plain, log: Log(), runner: ProcessRunner())
        return StyleCatalog.baseStyleDirectory
    }

    static func preparedDirectory() throws -> URL {
        try blocking { try await directory() }
    }
}
