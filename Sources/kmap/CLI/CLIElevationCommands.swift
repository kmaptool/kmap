import Foundation

/// Elevation rasters on their own: read, converted to `.hgt`, fetched and costed, each
/// for comparison against the tool it stands in for.
extension CLI {
    /// Converts one degree cell of GeoTIFF tiles into `.hgt`, for comparison against GDAL's
    /// output from the same tiles.
    ///
    ///     kmap tif2hgt N44E034 --dir tiles --out mine.hgt
    static func tif2hgt(_ arguments: [String]) -> Int32 {
        let flags = Flags(arguments, valued: ["dir", "out"])
        guard let cell = flags.positionals.first, let directory = flags.value("dir"),
              let out = flags.value("out") else {
            return CLIOutput.failure(
                "usage: kmap tif2hgt <cell> --dir <tiles> --out <file.hgt>", code: 2)
        }
        let sign = cell.hasPrefix("S") ? -1 : 1
        let east = cell.dropFirst().firstIndex(where: { $0 == "E" || $0 == "W" })
        guard let east else {
            return CLIOutput.failure("bad cell name: \(cell)", code: 2)
        }
        let lat = sign * (Int(cell[cell.index(after: cell.startIndex)..<east]) ?? 0)
        let lonSign = cell[east] == "W" ? -1 : 1
        let lon = lonSign * (Int(cell[cell.index(after: east)...]) ?? 0)

        let root = URL(fileURLWithPath: directory)
        let mosaic = HGTConversion.Mosaic { lat, lon in
            let file = root.appendingPathComponent(
                "\(CopernicusDEM.cellName(lat: lat, lon: lon)).tif")
            return FileTools.exists(file) ? file : nil
        }
        do {
            let started = Date()
            let count = try HGTConversion.write(cell: (lat: lat, lon: lon), from: mosaic,
                                                to: URL(fileURLWithPath: out))
            let seconds = Date().timeIntervalSince(started)
            CLILog.line("\(count) node(s) written in " + String(format: "%.1f s", seconds))
            CLIOutput.result(["out": .string(out), "cell": .string(cell),
                              "nodes": .int(count), "seconds": .double(seconds)])
            return 0
        } catch {
            return CLIOutput.failure("\(error)")
        }
    }

    /// Reads a GeoTIFF with kmap's own reader, for comparison against GDAL's.
    ///
    ///     kmap tif cop.tif --dump samples.f32
    static func tif(_ arguments: [String]) -> Int32 {
        let flags = Flags(arguments, valued: ["dump"])
        guard let path = flags.positionals.first else {
            return CLIOutput.failure("usage: kmap tif <file.tif> [--dump <out.f32>]",
                                     code: 2)
        }
        do {
            let started = Date()
            let tiff = try GeoTIFF(contentsOf: URL(fileURLWithPath: path))
            CLILog.line("\(tiff.width)×\(tiff.height)")
            CLILog.line(String(format: "sample (0,0) at %.9f, %.9f", tiff.originLon, tiff.originLat))
            CLILog.line(String(format: "step %.12f lon, %.12f lat", tiff.stepLon, tiff.stepLat))
            if let dump = flags.value("dump") {
                var out = Data(capacity: tiff.width * tiff.height * 4)
                for r in 0..<tiff.height {
                    for value in try tiff.row(r) {
                        withUnsafeBytes(of: value.bitPattern.littleEndian) {
                            out.append(contentsOf: $0)
                        }
                    }
                }
                try out.write(to: URL(fileURLWithPath: dump))
                CLILog.line("wrote \(out.count) bytes")
            }
            let seconds = Date().timeIntervalSince(started)
            CLILog.line(String(format: "read in %.1f s", seconds))
            CLIOutput.result(["width": .int(tiff.width), "height": .int(tiff.height),
                              "originLon": .double(tiff.originLon),
                              "originLat": .double(tiff.originLat),
                              "stepLon": .double(tiff.stepLon),
                              "stepLat": .double(tiff.stepLat),
                              "seconds": .double(seconds)])
            return 0
        } catch {
            return CLIOutput.failure("\(error)")
        }
    }

    /// Fetches one elevation tile through kmap's own downloaders, for comparison against the
    /// tile pyhgtmap fetches for the same name.
    ///
    ///     kmap fetch-dem N44E034 --source view3
    static func fetchDEM(_ arguments: [String]) async -> Int32 {
        let flags = Flags(arguments, valued: ["source"])
        guard let area = flags.positionals.first else {
            return CLIOutput.failure("usage: kmap fetch-dem <area> [--source view1|view3]",
                                     code: 2)
        }
        let source = flags.value("source") ?? "view3"
        guard source.hasPrefix("view"), let resolution = Int(source.dropFirst(4)),
              resolution == 1 || resolution == 3 else {
            return CLIOutput.failure("unknown source: \(source)", code: 2)
        }

        let log = Log(showing: CLIOutput.showing)
        let runner = ProcessRunner()
        let downloader = Downloader(log: log)
        do {
            var index = try await ViewfinderDEM.index(resolution, downloader: downloader) {
                CLILog.line($0)
            }
            CLILog.line("index: \(index.entries.count) archive(s),"
                  + " \(index.urls(for: area).count) claim \(area)")
            let file = try await ViewfinderDEM.fetch(area, resolution: resolution,
                                                     index: &index, downloader: downloader,
                                                     runner: runner) { CLILog.line($0) }
            CLILog.line("\(file.path)  \(FileTools.size(of: file)) bytes")
            CLIOutput.result(["area": .string(area), "source": .string(source),
                              "file": .string(file.path),
                              "bytes": .int(Int(FileTools.size(of: file))),
                              "archives": .int(index.entries.count)])
            return 0
        } catch {
            return CLIOutput.failure("\(error)")
        }
    }

    /// What the elevation for a region will cost to download, per source, before any
    /// build: the same cells and the same source chain the build fetches.
    ///
    ///     kmap dem-cost crimean-fed-district --sources=copernicus1,copernicus3
    static func demCost(_ arguments: [String]) async -> Int32 {
        let flags = Flags(arguments, valued: ["sources"])
        guard let regionID = flags.positionals.first else {
            return CLIOutput.failure("usage: kmap dem-cost <region>[+<region>…]"
                                     + " [--sources=<list>]", code: 2)
        }
        let sources = flags.value("sources") ?? BuildRecipe.recommendedDEMSources

        let index = RegionIndex()
        do {
            try await index.load()
        } catch {
            return CLIOutput.failure("\(error.localizedDescription)")
        }
        var chosen: [Region] = []
        for id in regionID.split(separator: "+").map(String.init) {
            guard let found = index.region(id) else {
                return CLIOutput.failure("no region with id \"\(id)\""
                                         + " — try `kmap regions \(id)`", code: 2)
            }
            chosen.append(found)
        }

        let started = Date()
        let cells = await ElevationCost.cells(of: chosen)
        let estimates = await ElevationCost.estimate(sources: sources, cells: cells)
        CLILog.line("\(chosen.map(\.name).joined(separator: " + ")):"
                    + " \(cells.count) cell(s) after the outline trim")
        for e in estimates {
            var line = "\(e.source): "
            if e.cached > 0 { line += "\(e.cached) cached · " }
            if e.wanted == 0 {
                line += "nothing to fetch — cached or already covered"
            } else if let bytes = e.bytes, bytes > 0 {
                line += "about \(Fmt.bytes(bytes)) — "
                line += e.archives > 0 ? "\(e.archives) zone archive(s)"
                                       : "\(e.published) tile(s)"
                line += e.exact ? ", every size asked" : ", measured on \(e.sampled)"
                if let note = e.note { line += " · \(note)" }
            } else if e.bytes == 0 {
                line += e.note ?? "nothing to fetch"
            } else {
                line += e.note ?? "\(e.wanted) cell(s), unmeasured"
            }
            CLILog.line(line)
        }
        let total = estimates.reduce(Int64(0)) { $0 + max(0, $1.bytes ?? 0) }
        if estimates.filter({ ($0.bytes ?? 0) > 0 }).count > 1 {
            CLILog.line("\(Fmt.bytes(total)) to download in all")
        }
        CLIOutput.result([
            "regions": .array(chosen.map { .string($0.id) }),
            "sources": .string(sources),
            "cells": .int(cells.count),
            "totalBytes": .int(Int(total)),
            "estimates": .array(estimates.map { e in
                var fields: [String: JSONValue] = [
                    "source": .string(e.source),
                    "cells": .int(e.cells),
                    "cached": .int(e.cached),
                    "wanted": .int(e.wanted),
                    "published": .int(e.published),
                    "exact": .bool(e.exact),
                    "sampled": .int(e.sampled),
                    "archives": .int(e.archives),
                ]
                fields["bytes"] = e.bytes.map { .int(Int($0)) } ?? .null
                if let note = e.note { fields["note"] = .string(note) }
                return .object(fields)
            }),
            "seconds": .double(Date().timeIntervalSince(started)),
        ])
        return 0
    }
}
