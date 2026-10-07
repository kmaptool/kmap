#if !os(Windows)
import XCTest

@testable import kmap

/// Every patch edit finds its anchor in the mkgmap source, applied in order.
final class MkgmapPatchEditsTests: XCTestCase {
    func testEveryEditFindsItsAnchor() throws {
        let archive = URL(
            fileURLWithPath: ("~/.kmap/tools/mkgmap/mkgmap-r4924-src.zip" as NSString).expandingTildeInPath
        )
        try XCTSkipUnless(FileManager.default.fileExists(atPath: archive.path), "no mkgmap source on this machine")
        var texts: [String: String] = [:]
        for (file, anchor, replacement) in Toolchain.mkgmapSourceEdits {
            if texts[file] == nil {
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                unzip.arguments = ["-p", archive.path, "mkgmap-r4924/src/" + file]
                let pipe = Pipe()
                unzip.standardOutput = pipe
                try unzip.run()
                texts[file] = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                unzip.waitUntilExit()
            }
            let text = try XCTUnwrap(texts[file])
            let found = try XCTUnwrap(text.range(of: anchor), "\(file): anchor not found")
            texts[file] = text.replacingCharacters(in: found, with: replacement)
        }
    }
}
#endif
