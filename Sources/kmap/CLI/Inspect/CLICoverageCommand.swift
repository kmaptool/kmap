import Foundation

/// `kmap coverage`: whether a built map's tiles cover the ground they claim. Every tile's
/// box, the box around them all, and each sample point belonging to no tile. Exits 1
/// when there are holes.
extension CLI {
    /// Degrees between the probes unless `--step` says otherwise.
    private static let coverageStep = 0.25
    /// Most holes listed by hand; the data carries them all.
    private static let mostHolesShown = 40

    static func coverage(_ arguments: [String]) -> Int32 {
        let flags = Flags(arguments, valued: ["step"])
        guard let path = flags.positionals.first, !path.hasPrefix("-") else {
            return CLIOutput.refuse("usage: kmap coverage <map.img> [--step \(coverageStep)] [--quiet]")
        }
        let step = flags.double("step") ?? coverageStep
        let url = URL(fileURLWithPath: path)
        let tiles = MapCoverage.tiles(in: url)
        guard let report = MapCoverage.check(tiles, step: step) else {
            return CLIOutput.refuse(t("no map tiles found"))
        }
        if !flags.has("quiet") {
            for tile in report.tiles {
                CLILog.line(
                    String(
                        format: "%@  %9.4f %9.4f  ->  %9.4f %9.4f",
                        tile.name,
                        tile.minLat,
                        tile.minLon,
                        tile.maxLat,
                        tile.maxLon
                    )
                )
            }
        }
        CLILog.line(
            String(
                format: "covered: %.4f %.4f -> %.4f %.4f   (%d tiles)",
                report.minLat,
                report.minLon,
                report.maxLat,
                report.maxLon,
                report.tiles.count
            )
        )
        CLILog.line(t("%d of %d sample(s) fall in no tile", report.holes.count, report.sampled))
        for hole in report.holes.prefix(mostHolesShown) {
            CLILog.line(String(format: "  hole %.2f %.2f", hole.lat, hole.lon))
        }
        if report.holes.count > mostHolesShown {
            CLILog.line(t("  ... and %d more", report.holes.count - mostHolesShown))
        }
        CLIOutput.result([
            "map": .string(url.path),
            "tiles": .array(
                report.tiles.map {
                    [
                        "name": .string($0.name), "minLat": .double($0.minLat),
                        "minLon": .double($0.minLon), "maxLat": .double($0.maxLat),
                        "maxLon": .double($0.maxLon)
                    ]
                }
            ),
            "covered": [
                "minLat": .double(report.minLat), "minLon": .double(report.minLon),
                "maxLat": .double(report.maxLat), "maxLon": .double(report.maxLon)
            ],
            "sampled": .int(report.sampled),
            "holes": .array(report.holes.map { ["lat": .double($0.lat), "lon": .double($0.lon)] }),
            "step": .double(step)
        ])
        return report.holes.isEmpty ? 0 : 1
    }
}
