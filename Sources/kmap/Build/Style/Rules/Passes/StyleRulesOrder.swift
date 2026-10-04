import Foundation

/// Rule order that matters only under a borrowed look.
extension StyleCatalog {
    /// Puts the bus-stop rule above the platform rule.
    ///
    /// mkgmap draws both with one code, so their order never mattered to it. A borrowed
    /// style may draw them apart - a bus stop and a railway station are not the same
    /// sign - and a modern OSM bus stop carries `public_transport=platform` beside
    /// `highway=bus_stop`. Whichever rule stands first wins, so the specific one goes
    /// first and a bus stop stays a bus stop.
    func busStopsBeforePlatforms(in directory: URL, log: Log) throws {
        let url = directory.appendingPathComponent("points")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var lines = text.components(separatedBy: "\n")
        guard
            let stop = lines.firstIndex(where: {
                $0.hasPrefix("highway=bus_stop | railway=tram_stop [")
            }),
            let platform = lines.firstIndex(where: {
                $0.hasPrefix("public_transport=platform & (mkgmap:line2poi")
            }), platform < stop
        else { return }

        let rule = lines.remove(at: stop)
        lines.insert(rule, at: platform)
        try FileTools.write(lines.joined(separator: "\n"), to: url)
        log.append("bus stops read before platforms, so a borrowed look can tell them apart")
    }
}
