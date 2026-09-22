import Foundation

/// `kmap dem-cost`: what the elevation for a region will weigh, per source, before any
/// build. The same cells and the same source chain the build fetches.
///
///     kmap dem-cost crimean-fed-district --sources=copernicus1,copernicus3
extension CLI {
    static func demCost(_ arguments: [String]) async -> Int32 {
        let flags = Flags(arguments, valued: ["sources"])
        guard let regionID = flags.positionals.first else {
            return CLIOutput.refuse("usage: kmap dem-cost <region>[+<region>…] [--sources=<list>]")
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
                return CLIOutput.refuse("no region with id \"\(id)\" — try `kmap regions \(id)`")
            }
            chosen.append(found)
        }

        let started = Date()
        let cells = await ElevationCost.cells(of: chosen)
        let estimates = await ElevationCost.estimate(sources: sources, cells: cells)
        CLILog.line("\(chosen.map(\.name).joined(separator: " + ")): \(cells.count) cell(s) after the outline trim")
        for e in estimates { CLILog.line(describe(e)) }
        let total = estimates.reduce(Int64(0)) { $0 + max(0, $1.bytes ?? 0) }
        if estimates.filter({ ($0.bytes ?? 0) > 0 }).count > 1 {
            CLILog.line("\(Fmt.bytes(total)) to download in all")
        }
        CLIOutput.result([
            "regions": .array(chosen.map { .string($0.id) }),
            "sources": .string(sources),
            "cells": .int(cells.count),
            "totalBytes": .int(Int(total)),
            "estimates": .array(estimates.map(estimateAsData)),
            "seconds": .double(Date().timeIntervalSince(started))
        ])
        return 0
    }

    /// One source on one line: what is cached, what is wanted, and how the size is known.
    private static func describe(_ e: ElevationCost.Estimate) -> String {
        var line = "\(e.source): "
        if e.cached > 0 { line += "\(e.cached) cached · " }
        if e.wanted == 0 {
            line += "nothing to fetch — cached or already covered"
        } else if let bytes = e.bytes, bytes > 0 {
            line += "about \(Fmt.bytes(bytes)) — "
            line += e.archives > 0 ? "\(e.archives) zone archive(s)" : "\(e.published) tile(s)"
            line += e.exact ? ", every size asked" : ", measured on \(e.sampled)"
            if let note = e.note { line += " · \(note)" }
        } else if e.bytes == 0 {
            line += e.note ?? "nothing to fetch"
        } else {
            line += e.note ?? "\(e.wanted) cell(s), unmeasured"
        }
        return line
    }

    private static func estimateAsData(_ e: ElevationCost.Estimate) -> JSONValue {
        var fields: [String: JSONValue] = [
            "source": .string(e.source),
            "cells": .int(e.cells),
            "cached": .int(e.cached),
            "wanted": .int(e.wanted),
            "published": .int(e.published),
            "exact": .bool(e.exact),
            "sampled": .int(e.sampled),
            "archives": .int(e.archives)
        ]
        fields["bytes"] = e.bytes.map { .int(Int($0)) } ?? .null
        if let note = e.note { fields["note"] = .string(note) }
        return .object(fields)
    }
}
