import Foundation

/// `kmap tif`: a GeoTIFF read with kmap's own reader, for comparison against GDAL's.
///
///     kmap tif cop.tif --dump samples.f32
extension CLI {
    static func tif(_ arguments: [String]) -> Int32 {
        let flags = Flags(arguments, valued: ["dump"])
        guard let path = flags.positionals.first else {
            return CLIOutput.refuse("usage: kmap tif <file.tif> [--dump <out.f32>]")
        }
        do {
            let started = Date()
            let tiff = try GeoTIFF(contentsOf: URL(fileURLWithPath: path))
            CLILog.line("\(tiff.width)×\(tiff.height)")
            CLILog.line(String(format: "sample (0,0) at %.9f, %.9f", tiff.originLon, tiff.originLat))
            CLILog.line(String(format: "step %.12f lon, %.12f lat", tiff.stepLon, tiff.stepLat))
            if let dump = flags.value("dump") {
                let out = try samples(of: tiff)
                try out.write(to: URL(fileURLWithPath: dump))
                CLILog.line("wrote \(out.count) bytes")
            }
            let seconds = Date().timeIntervalSince(started)
            CLILog.line(String(format: "read in %.1f s", seconds))
            CLIOutput.result([
                "width": .int(tiff.width), "height": .int(tiff.height),
                "originLon": .double(tiff.originLon),
                "originLat": .double(tiff.originLat),
                "stepLon": .double(tiff.stepLon),
                "stepLat": .double(tiff.stepLat),
                "seconds": .double(seconds)
            ])
            return 0
        } catch {
            return CLIOutput.failure("\(error)")
        }
    }

    /// Every sample, row by row, as little-endian float32.
    private static func samples(of tiff: GeoTIFF) throws -> Data {
        var out = Data(capacity: tiff.width * tiff.height * MemoryLayout<Float>.size)
        for r in 0..<tiff.height {
            for value in try tiff.row(r) {
                withUnsafeBytes(of: value.bitPattern.littleEndian) { out.append(contentsOf: $0) }
            }
        }
        return out
    }
}
