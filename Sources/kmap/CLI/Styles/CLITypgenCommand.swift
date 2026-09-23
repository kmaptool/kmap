import Foundation

/// `kmap typgen`: the TYP source a palette table stands for, the same text a build with
/// that shipped style compiles.
extension CLI {
    /// The family id written when `--fid` says nothing: the one the shipped styles carry.
    private static let defaultFamilyID = 6325

    static func typgen(_ arguments: [String]) -> Int32 {
        let flags = Flags(arguments, valued: ["fid", "out"])
        guard let path = flags.positionals.first else {
            return CLIOutput.refuse("typgen needs a palette.txt path")
        }
        // Not `flatMap(Int.init)`: a function reference drops the label and resolves to
        // the hex-parsing `Int(hex:)`, so --fid=6326 would become 25382.
        let fid = flags.int("fid") ?? defaultFamilyID
        do {
            let source = Paths.expand(path)
            let palette = try StylePalette.read(String(contentsOf: source, encoding: .utf8))
            // Icon and pattern sections live beside the table, ready-made.
            let text = TypGenerator.text(
                from: palette,
                fid: fid,
                points: sibling("points.txt", of: source),
                graphics: sibling("graphics.txt", of: source)
            )
            if let out = flags.value("out") {
                let destination = Paths.expand(out)
                try FileTools.write(text, to: destination)
                CLILog.line(
                    "\(Paths.display(destination))  \(palette.polygons.count)"
                        + " polygon(s), \(palette.lines.count) line(s), FID \(fid)"
                )
                CLIOutput.result([
                    "out": .string(destination.path),
                    "polygons": .int(palette.polygons.count),
                    "lines": .int(palette.lines.count),
                    "familyID": .int(fid)
                ])
            } else {
                CLILog.line(text)
                CLIOutput.result([
                    "polygons": .int(palette.polygons.count),
                    "lines": .int(palette.lines.count),
                    "familyID": .int(fid),
                    "text": .string(text)
                ])
            }
            return 0
        } catch {
            return CLIOutput.failure("\(error)")
        }
    }

    /// A file next to `source`, or nothing where there is none.
    private static func sibling(_ name: String, of source: URL) -> String {
        let url = source.deletingLastPathComponent().appendingPathComponent(name)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}
