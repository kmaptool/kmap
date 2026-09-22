import Foundation

/// `kmap verify`: a structural check on a built map before it goes to the device. With no
/// path, everything in the output folder.
extension CLI {
    /// The label column of a finding.
    private static let findingLabelColumn = 14

    static func verify(_ arguments: [String]) -> Int32 {
        let paths = Flags(arguments).positionals
        let checked = paths.isEmpty ? builtMaps(in: SettingsStore().settings.outputURL) : paths
        guard !checked.isEmpty else {
            CLILog.line("no maps to check — pass a .img path, or build one first")
            CLIOutput.result(["maps": .array([])])
            return 0
        }

        var failed = false
        var reported: [JSONValue] = []
        for path in checked {
            let report = MapVerifier.verify(Paths.expand(path))
            CLILog.line("\n\(report.url.lastPathComponent)")
            for finding in report.findings {
                let label = finding.label.padding(toLength: findingLabelColumn, withPad: " ", startingAt: 0)
                CLILog.line("  \(mark(finding.level))  \(label)  \(finding.detail)")
            }
            reported.append([
                "file": .string(report.url.lastPathComponent),
                "path": .string(report.url.path),
                "ok": .bool(!report.failed),
                "findings": .array(
                    report.findings.map {
                        [
                            "level": .string("\($0.level)"),
                            "label": .string($0.label),
                            "detail": .string($0.detail)
                        ]
                    }
                )
            ])
            if report.failed { failed = true }
        }
        CLIOutput.result(["maps": .array(reported)])
        return failed ? 1 : 0
    }

    /// Every .img in the folder and one level of sub-folders, where a build lands its map.
    private static func builtMaps(in root: URL) -> [String] {
        var found = FileTools.contents(of: root, extension: "img").map(\.path)
        for entry in FileTools.contents(of: root) {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue
            else { continue }
            found.append(contentsOf: FileTools.contents(of: entry, extension: "img").map(\.path))
        }
        return found
    }

    private static func mark(_ level: MapVerifier.Finding.Level) -> String {
        switch level {
        case .ok: return "ok  "
        case .warn: return "warn"
        case .fail: return "FAIL"
        }
    }
}
