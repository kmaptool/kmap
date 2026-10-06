import Foundation

/// `kmap tif2hgt`: one degree cell of GeoTIFF tiles converted into `.hgt`, for comparison
/// against GDAL's output from the same tiles.
///
///     kmap tif2hgt N44E034 --dir tiles --out mine.hgt
extension CLI {
    static func tif2hgt(_ arguments: [String]) -> Int32 {
        let flags = Flags(arguments, valued: ["dir", "out"])
        if let refused = flags.refusal("tif2hgt", knows: ["dir", "out"], positionals: 1) { return refused }
        guard let cell = flags.positionals.first, let directory = flags.value("dir"), let out = flags.value("out")
        else {
            return CLIOutput.refuse("usage: kmap tif2hgt <cell> --dir <tiles> --out <file.hgt>")
        }
        guard let (lat, lon) = parseCell(cell) else {
            return CLIOutput.refuse("bad cell name: \(cell)")
        }
        let root = URL(fileURLWithPath: directory)
        let mosaic = HGTConversion.Mosaic { lat, lon in
            let file = root.appendingPathComponent("\(HGTName.of(lat: lat, lon: lon)).tif")
            return FileTools.exists(file) ? file : nil
        }
        do {
            let started = Date()
            let count = try HGTConversion.write(cell: (lat: lat, lon: lon), from: mosaic, to: URL(fileURLWithPath: out))
            let seconds = Date().timeIntervalSince(started)
            CLILog.line("\(count) node(s) written in " + String(format: "%.1f s", seconds))
            CLIOutput.result([
                "out": .string(out), "cell": .string(cell),
                "nodes": .int(count), "seconds": .double(seconds)
            ])
            return 0
        } catch {
            return CLIOutput.failure("\(CLIOutput.said(error))")
        }
    }

    /// `N44E034` as degrees, south and west negative.
    private static func parseCell(_ cell: String) -> (lat: Int, lon: Int)? {
        guard cell.hasPrefix("N") || cell.hasPrefix("S") else { return nil }
        let body = cell.dropFirst()
        guard let east = body.firstIndex(where: { $0 == "E" || $0 == "W" }),
            let latDegrees = Int(body[..<east]), let lonDegrees = Int(cell[cell.index(after: east)...]),
            (0...90).contains(latDegrees), (0...180).contains(lonDegrees)
        else { return nil }
        return ((cell.hasPrefix("S") ? -1 : 1) * latDegrees, (cell[east] == "W" ? -1 : 1) * lonDegrees)
    }
}
