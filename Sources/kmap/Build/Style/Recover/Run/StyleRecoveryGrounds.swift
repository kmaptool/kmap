import Foundation

extension StyleRecovery {
    /// One ground per extract, clipped to the frame: identification can happen only
    /// where an extract covers the map, and one box around distant extracts would
    /// read the gap between them too.
    ///
    /// A header that carries no box is measured from the file's own nodes instead: the
    /// extract is matched against below all the same, so its ground has to be read, and
    /// one pass over one file beats reading the whole frame in its place.
    static func grounds(
        of extracts: [URL],
        frame: BBox,
        named: Bool,
        log: Log
    ) throws -> (grounds: [BBox], wholeFrame: Bool) {
        var grounds: [BBox] = []
        var wholeFrame = false
        for extract in extracts {
            let reader = PBFReader(url: extract)
            var box = ((try? reader.headerBBox()) ?? nil).map {
                BBox(
                    minLon: $0.minLon,
                    minLat: $0.minLat,
                    maxLon: $0.maxLon,
                    maxLat: $0.maxLat
                )
            }
            if box == nil {
                log.step(
                    "\(extract.lastPathComponent) carries no bounding box in its"
                        + " header — reading its nodes for one"
                )
                do {
                    // No nodes at all: the extract covers no ground, and nothing it holds
                    // can name anything on the map.
                    guard let measured = try reader.nodeBounds() else { continue }
                    box = measured
                    log.append("its own nodes lie in \(measured.display)")
                } catch {
                    log.warn(
                        "\(extract.lastPathComponent) cannot be read for its bounds,"
                            + " so the whole frame is searched — this takes longer"
                    )
                    grounds = [frame]
                    wholeFrame = true
                    break
                }
            }
            guard let within = box?.intersection(frame), within.isValid else {
                // Named by hand, an extract beside the map is a mistake worth saying.
                if named { throw Trouble.extractMissesMap(extract, frame) }
                continue
            }
            grounds.append(within)
        }
        return (grounds, wholeFrame)
    }
}
