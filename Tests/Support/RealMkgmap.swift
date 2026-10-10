import Foundation
import XCTest

@testable import kmap

/// Copied into the test root so the toolchain finds it there. Skips the test where the
/// machine has none, or it cannot be probed.
enum RealMkgmap {
    @discardableResult
    static func install() throws -> Toolchain {
        let realJar = URL(
            fileURLWithPath: ("~/.kmap/tools/mkgmap/mkgmap.jar" as NSString).expandingTildeInPath
        )
        try XCTSkipUnless(FileManager.default.fileExists(atPath: realJar.path), "no mkgmap.jar on this machine")
        let jar = Paths.tools.appendingPathComponent("mkgmap/mkgmap.jar")
        Paths.ensure(jar.deletingLastPathComponent())
        if !FileManager.default.fileExists(atPath: jar.path) {
            try FileManager.default.copyItem(at: realJar, to: jar)
        }
        // mkgmap reads no OSM file without its libraries.
        let realLib = realJar.deletingLastPathComponent().appendingPathComponent("lib", isDirectory: true)
        let lib = jar.deletingLastPathComponent().appendingPathComponent("lib", isDirectory: true)
        if FileManager.default.fileExists(atPath: realLib.path), !FileManager.default.fileExists(atPath: lib.path) {
            try FileManager.default.copyItem(at: realLib, to: lib)
        }
        let toolchain = Toolchain(settings: SettingsStore())
        try XCTSkipUnless(toolchain.findMkgmap() != nil, "mkgmap could not be probed")
        return toolchain
    }
}
