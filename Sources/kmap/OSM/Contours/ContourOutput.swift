import Foundation

/// Writes traced contours as a PBF for mkgmap to read.
///
/// The tags are the ones the style expects and pyhgtmap wrote before it: `contour` and
/// `ele` on every line, and `contour_ext` saying whether this is one of the heavier lines
/// drawn every fifth or tenth step.
enum ContourOutput {
    /// Objects handed to the writer at a time. It bounds its own blocks, so these only
    /// decide how much is held in memory before a block is built -- a tile's worth of
    /// contours is hundreds of thousands of nodes.
    private static let nodesPerBatch = 8_000
    private static let waysPerBatch = 4_000

    /// First invented ids for contour nodes and ways, clear of the ids OSM itself uses.
    /// A multi-cell build takes one slice per cell, so no two cells collide.
    static let nodeIDBase: Int64 = 20_000_000_000
    static let wayIDBase: Int64 = 5_000_000_000
    static let nodeIDSlice: Int64 = 200_000_000
    static let wayIDSlice: Int64 = 50_000_000

    static func write(_ lines: [Contours.Line], to url: URL,
                      nodeStart: Int64, wayStart: Int64,
                      major: Int, medium: Int) throws -> (nodes: Int, ways: Int) {
        let writer = try PBFWriter(to: url)
        writer.header()

        // Nodes first and in ascending order, which is what the splitter insists on. Each
        // line gets its own, even where two contours cross at a saddle: sharing them would
        // save a few thousand nodes and cost the ability to number them by walking.
        var id = nodeStart
        var nodes: [PBFWriter.Node] = []
        var ways: [PBFWriter.Way] = []
        var wayID = wayStart
        var written = 0

        for line in lines {
            var refs: [Int64] = []
            refs.reserveCapacity(line.points.count)
            for point in line.points {
                nodes.append(PBFWriter.Node(id: id, lat: point.lat, lon: point.lon, tags: []))
                refs.append(id)
                id += 1
            }
            // A closed line ends where it began, and mkgmap wants that said with the same
            // node rather than two nodes in the same place.
            if line.closed, refs.count > 2 {
                nodes.removeLast()
                refs[refs.count - 1] = refs[0]
                id -= 1
            }
            ways.append(PBFWriter.Way(id: wayID, refs: refs, tags: [
                ("contour", "elevation"),
                ("ele", "\(line.elevation)"),
                ("contour_ext", extra(line.elevation, major: major, medium: medium)),
            ]))
            wayID += 1

            if nodes.count >= Self.nodesPerBatch {
                ContourTiming.measure("hand over") { writer.nodes(nodes) }
                written += nodes.count
                nodes.removeAll(keepingCapacity: true)
            }
        }
        if !nodes.isEmpty {
            ContourTiming.measure("hand over") { writer.nodes(nodes) }
            written += nodes.count
        }
        ContourTiming.measure("hand over") {
            for batch in stride(from: 0, to: ways.count, by: Self.waysPerBatch) {
                writer.ways(Array(ways[batch..<min(batch + Self.waysPerBatch, ways.count)]))
            }
        }
        try ContourTiming.measure("finish") { try writer.finish() }
        return (written, ways.count)
    }

    /// Every tenth line is major, every fifth medium, the rest minor -- which is how the
    /// style knows to draw one heavier than the next.
    static func extra(_ elevation: Int, major: Int, medium: Int) -> String {
        if major > 0, elevation % major == 0 { return "elevation_major" }
        if medium > 0, elevation % medium == 0 { return "elevation_medium" }
        return "elevation_minor"
    }
}
