import Foundation

/// `kmap img-elements`: a map's detail-level elements in the form mkgmap's reader
/// produces, for a byte-for-byte comparison.
extension CLI {
    /// `kmap img-elements <map.img> --out <dump.bin> [--ground minLat,minLon,maxLat,maxLon]...`
    /// writes the map's detail-level elements in the binary form mkgmap's reader produces,
    /// for a byte-for-byte comparison. `--extended` adds extended-type polygons and points.
    static func imgElements(_ arguments: [String]) -> Int32 {
        let flags = Flags(arguments, valued: ["out", "ground", "res"])
        guard let path = flags.positionals.first, let out = flags.value("out") else {
            return CLIOutput.failure("usage: kmap img-elements <map.img> --out <dump.bin>"
                                     + " [--ground a,b,c,d]… [--extended]"
                                     + " [--coarse] [--res=N]", code: 2)
        }
        var grounds: [BBox] = []
        for spec in flags.values("ground") {
            let parts = spec.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 4 else {
                return CLIOutput.failure("bad --ground: \(spec)", code: 2)
            }
            grounds.append(BBox(minLon: parts[1], minLat: parts[0], maxLon: parts[3], maxLat: parts[2]))
        }
        if grounds.isEmpty { grounds = [BBox(minLon: -180, minLat: -90, maxLon: 180, maxLat: 90)] }
        do {
            var dump = ElementDumper.Dump()
            let started = Date()
            try ImgElements.read(img: Paths.expand(path),
                                 grounds: grounds.map(ImgElements.Ground.init),
                                 extendedAreasAndPoints: flags.has("extended"),
                                 coarserLevels: flags.has("coarse"),
                                 resolution: flags.value("res").flatMap { Int($0) },
                                 tick: {}) { kind, type, coords in
                let from = dump.cells.count
                for c in coords { dump.cells.append(GarminGrid.pack(latUnit: c.lat, lonUnit: c.lon)) }
                dump.elements.append(ElementDumper.Element(kind: kind, type: type,
                                                           from: Int32(from), count: Int32(coords.count)))
            }
            try ElementDumper.write(dump, to: Paths.expand(out))
            let seconds = Date().timeIntervalSince(started)
            CLILog.line("\(dump.count) element(s), \(dump.cells.count) vertice(s) in "
                  + String(format: "%.1f s", seconds))
            CLIOutput.result(["out": .string(out), "elements": .int(dump.count),
                              "vertices": .int(dump.cells.count),
                              "seconds": .double(seconds)])
            return 0
        } catch {
            return CLIOutput.failure("\(error)")
        }
    }
}
