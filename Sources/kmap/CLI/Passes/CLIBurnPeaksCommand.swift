import Foundation

/// `kmap burn-peaks`: OSM summit heights written into a copy of the .hgt tiles, so the
/// DEM and the map agree.
extension CLI {
    /// Widest a rejected summit's name is printed.
    private static let rejectedNameWidth = 22

    static func burnPeaks(_ arguments: [String]) -> Int32 {
        let flags = Flags(arguments, valued: ["pbf", "hgt-dir", "out", "threshold", "radius"])
        let pbfs = flags.values("pbf")
        guard !pbfs.isEmpty, let source = flags.value("hgt-dir"), let out = flags.value("out") else {
            return CLIOutput.refuse(
                "usage: kmap burn-peaks --pbf <file>... --hgt-dir <dir> --out <dir>"
                    + " [--threshold M] [--radius M] [--quiet]"
            )
        }
        var burn = BurnPeaks(
            extracts: pbfs.map { URL(fileURLWithPath: $0) },
            hgt: URL(fileURLWithPath: source),
            out: URL(fileURLWithPath: out)
        )
        burn.threshold = flags.double("threshold") ?? burn.threshold
        burn.radius = flags.double("radius") ?? burn.radius

        do {
            let report = try burn.run()
            let gains = report.gains.sorted()
            CLIOutput.result([
                "peaks": .int(report.peaks), "raised": .int(report.raised),
                "cells": .int(report.cells),
                "already": .int(report.already), "rejected": .int(report.rejected.count),
                "outside": .int(report.outside),
                "tiles": .array(report.written.map(JSONValue.string)),
                "gain": gains.isEmpty
                    ? .null
                    : [
                        "median": .int(gains[gains.count / 2]),
                        "mean": .double(mean(of: gains)),
                        "largest": .int(gains.last ?? 0)
                    ]
            ])
            if flags.has("quiet") {
                CLILog.line(
                    "\(report.raised) summit height(s) written into \(report.written.count)"
                        + " tile(s), \(report.rejected.count) rejected as bad OSM"
                )
            } else {
                printBurnReport(report, gains: gains)
            }
            return 0
        } catch {
            return CLIOutput.failure("burn-peaks failed: \(error)")
        }
    }

    private static func printBurnReport(_ report: BurnPeaks.Report, gains: [Int]) {
        CLILog.line("summits with a usable height : \(report.peaks)")
        CLILog.line("  raised                     : \(report.raised)")
        CLILog.line("  cells raised               : \(report.cells)")
        CLILog.line("  already at or above `ele`  : \(report.already)")
        CLILog.line("  rejected as bad OSM        : \(report.rejected.count)")
        CLILog.line("  outside the cached tiles   : \(report.outside)")
        if !gains.isEmpty {
            CLILog.line(
                String(
                    format: "  gain: median %d m, mean %.1f m, largest %d m",
                    gains[gains.count / 2],
                    mean(of: gains),
                    gains.last ?? 0
                )
            )
        }
        CLILog.line(
            "tiles written                : "
                + (report.written.isEmpty ? "none" : report.written.joined(separator: ", "))
        )
        for item in report.rejected {
            let name = item.name.isEmpty ? "(unnamed)" : item.name
            CLILog.line(
                String(
                    format: "  rejected %-\(rejectedNameWidth)@ ele %-7.0f terrain %-7@ %@",
                    String(name.prefix(rejectedNameWidth)) as NSString,
                    item.ele,
                    (item.terrain.map(String.init) ?? "n/a") as NSString,
                    item.why as NSString
                )
            )
        }
    }

    private static func mean(of values: [Int]) -> Double {
        Double(values.reduce(0, +)) / Double(values.count)
    }
}
