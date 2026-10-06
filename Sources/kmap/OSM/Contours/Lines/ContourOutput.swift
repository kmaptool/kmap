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

    /// First ids invented for contour nodes and ways: above OSM's own (about 1.4e10 nodes in
    /// 2026, growing 1e9 a year) and the passes' (from 2^40, 2^32 a region). A multi-cell
    /// build gives each cell its own slice.
    static let nodeIDBase: Int64 = 1 << 42
    static let wayIDBase: Int64 = 1 << 42
    static let nodeIDSlice: Int64 = 200_000_000
    static let wayIDSlice: Int64 = 50_000_000

    static func write(
        _ lines: [Contours.Line],
        to url: URL,
        nodeStart: Int64,
        wayStart: Int64,
        major: Int,
        medium: Int
    ) throws -> (nodes: Int, ways: Int) {
        // Past its slice a cell's ids run into the next cell's, and stop ascending.
        let nodeCount = lines.reduce(0) { $0 + $1.points.count }
        guard Int64(nodeCount) <= nodeIDSlice else { throw Trouble.tooManyNodes(nodeCount) }
        guard Int64(lines.count) <= wayIDSlice else { throw Trouble.tooManyLines(lines.count) }
        // A write that fails leaves no part of itself: the writer lands the file whole.
        return try writeWhole(
            lines,
            to: url,
            nodeStart: nodeStart,
            wayStart: wayStart,
            major: major,
            medium: medium
        )
    }

    enum Trouble: Error, CustomStringConvertible, LocalizedError {
        case tooManyNodes(Int)
        case tooManyLines(Int)

        var description: String {
            switch self {
            case .tooManyNodes(let count):
                "\(count) contour points in 1 degree cell, more than its share of ids -- use a wider interval"
            case .tooManyLines(let count):
                "\(count) contour lines in 1 degree cell, more than its share of ids -- use a wider interval"
            }
        }
        var errorDescription: String? { description }
    }

    private static func writeWhole(
        _ lines: [Contours.Line],
        to url: URL,
        nodeStart: Int64,
        wayStart: Int64,
        major: Int,
        medium: Int
    ) throws -> (nodes: Int, ways: Int) {
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
            ways.append(
                PBFWriter.Way(
                    id: wayID,
                    refs: refs,
                    tags: [
                        ("contour", "elevation"),
                        ("ele", "\(line.elevation)"),
                        ("contour_ext", extra(line.elevation, major: major, medium: medium))
                    ]
                )
            )
            wayID += 1

            if nodes.count >= Self.nodesPerBatch {
                // Handed over as a constant: a closure capturing the growing array itself
                // moves it to the heap, and every append above pays for that.
                let batch = nodes
                ContourTiming.measure("hand over") { writer.nodes(batch) }
                written += nodes.count
                nodes.removeAll(keepingCapacity: true)
            }
        }
        if !nodes.isEmpty {
            let batch = nodes
            ContourTiming.measure("hand over") { writer.nodes(batch) }
            written += nodes.count
        }
        let finished = ways
        ContourTiming.measure("hand over") {
            for batch in stride(from: 0, to: finished.count, by: Self.waysPerBatch) {
                writer.ways(Array(finished[batch..<min(batch + Self.waysPerBatch, finished.count)]))
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
