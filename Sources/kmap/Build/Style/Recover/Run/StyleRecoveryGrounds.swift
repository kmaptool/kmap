import Foundation

extension StyleRecovery {
    /// A ground per extract, clipped to the frame and cut to its region's outline where
    /// that is known: identification can happen only where an extract has data under the
    /// map, and 1 box around distant extracts would read the gap between them too. A
    /// frame across 180 deg is its 2 sides, each a ground of its own.
    ///
    /// A header that carries no box is measured from the file's own nodes instead: the
    /// extract is matched against below all the same, so its ground has to be read, and
    /// 1 pass over 1 file beats reading the whole frame in its place.
    static func grounds(
        of extracts: [(file: URL, outline: Region?)],
        frame: BBox,
        named: Bool,
        log: Log
    ) throws -> (grounds: [ImgElements.Ground], holders: [Region], wholeFrame: Bool) {
        var grounds: [ImgElements.Ground] = []
        // The same grounds as regions: what the share of the map under them is measured on.
        var holders: [Region] = []
        for (extract, outline) in extracts {
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
                    return (frame.sidesOf180.map { ImgElements.Ground($0) }, [], true)
                }
            }
            let within = frame.sidesOf180.compactMap { box?.intersection($0) }.filter(\.isValid)
            guard !within.isEmpty else {
                // Named by hand, an extract beside the map is a mistake worth saying.
                if named { throw Trouble.extractMissesMap(extract, frame) }
                continue
            }
            grounds += within.map { ImgElements.Ground($0, outline: outline) }
            if let outline {
                holders.append(outline)
            } else {
                let name = extract.lastPathComponent
                holders += within.map {
                    Region(id: name, name: name, parentID: nil, pbfURL: nil, bbox: $0, boxes: [$0])
                }
            }
        }
        return (grounds, holders, false)
    }
}
