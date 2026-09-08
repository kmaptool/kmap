import Foundation

/// RGN — the elements themselves: points, lines and areas, plain and extended,
/// read subdivision by subdivision.
extension ImgElements {
    struct Region {
        let data: Bytes
        let dataOffset: Int
        let extAreasOffset: Int, extLinesOffset: Int, extPointsOffset: Int

        init(_ raw: Data, tile: String) throws {
            data = Bytes(raw)
            guard data.count >= 0x1D else { throw Trouble.malformed(tile, "RGN too short") }
            let r = data
            let headerLength = Int(r.u16(at: 0))
            dataOffset = Int(r.u32(at: 0x15))
            if headerLength > 29, data.count >= 0x5D {
                extAreasOffset = Int(r.u32(at: 0x1D))
                extLinesOffset = Int(r.u32(at: 0x39))
                extPointsOffset = Int(r.u32(at: 0x55))
            } else {
                extAreasOffset = 0; extLinesOffset = 0; extPointsOffset = 0
            }
        }

        func read(_ division: Subdivision, extendedAreasAndPoints: Bool, tile: String,
                  emit: (ElementDumper.Kind, Int, [Coord]) throws -> Void) throws {
            var r = data
            // One vertex buffer reused for every element of the subdivision; `emit` copies
            // whatever it keeps before the buffer is filled again.
            var coords: [Coord] = []
            coords.reserveCapacity(256)
            // Where the subdivision's sections sit: pointers to the later ones lead,
            // one for every section that has something before it.
            let start = dataOffset + division.rgnStart
            let whole = division.rgnEnd - division.rgnStart
            guard start >= 0, start + whole <= data.count else {
                throw Trouble.malformed(tile, "subdivision past the end of RGN")
            }
            r.position = start
            let bounds = SectionBounds(&r, division: division, whole: whole)
            func begin(_ offset: Int) -> Int {
                offset == 0 ? start + bounds.headerLength : start + offset
            }
            let indexedOffset = bounds.indexedOffset, lineOffset = bounds.lineOffset
            let areaOffset = bounds.areaOffset
            let pointEnd = bounds.pointEnd, indexedEnd = bounds.indexedEnd
            let lineEnd = bounds.lineEnd, areaEnd = bounds.areaEnd

            // Lines, then polygons, then points: the order the RGN holds them in.
            if division.hasLines {
                r.position = begin(lineOffset)
                let end = start + lineEnd
                while r.position < end {
                    let type = try line(&r, division, polygon: false, tile: tile, into: &coords)
                    try emit(.line, type, coords)
                }
            }
            if division.extLinesSize > 0 {
                r.position = extLinesOffset + division.extLinesOffset
                let end = r.position + division.extLinesSize
                while r.position < end {
                    let type = try extendedLine(&r, division, polygon: false, tile: tile, into: &coords)
                    try emit(.line, type, coords)
                }
            }
            if division.hasAreas {
                r.position = begin(areaOffset)
                let end = start + areaEnd
                while r.position < end {
                    let type = try line(&r, division, polygon: true, tile: tile, into: &coords)
                    try emit(.area, type, coords)
                }
            }
            if extendedAreasAndPoints, division.extAreasSize > 0 {
                r.position = extAreasOffset + division.extAreasOffset
                let end = r.position + division.extAreasSize
                while r.position < end {
                    let type = try extendedLine(&r, division, polygon: true, tile: tile, into: &coords)
                    try emit(.area, type, coords)
                }
            }
            if division.hasIndexedPoints || division.hasPoints {
                if division.hasIndexedPoints {
                    r.position = begin(indexedOffset)
                    try points(&r, division, until: start + indexedEnd, tile: tile, emit: emit)
                }
                if division.hasPoints {
                    r.position = begin(0)
                    try points(&r, division, until: start + pointEnd, tile: tile, emit: emit)
                }
            }
            if extendedAreasAndPoints, division.extPointsSize > 0 {
                r.position = extPointsOffset + division.extPointsOffset
                let end = r.position + division.extPointsSize
                while r.position < end {
                    try extendedPoint(&r, division, tile: tile, emit: emit)
                }
            }
        }

        /// Where each plain element kind's records begin and end inside one
        /// subdivision's slice of the RGN. The slice opens with up to three u16 offsets,
        /// one for every section that has something before it; a section's end is the
        /// next section's start, and the last runs to the end of the slice.
        private struct SectionBounds {
            var headerLength = 0
            var indexedOffset = 0, lineOffset = 0, areaOffset = 0
            var pointEnd = 0, indexedEnd = 0, lineEnd = 0, areaEnd = 0

            init(_ r: inout Bytes, division: Subdivision, whole: Int) {
                if division.hasIndexedPoints && division.hasPoints {
                    indexedOffset = Int(r.u16()); headerLength += 2
                }
                if division.hasLines && (division.hasPoints || division.hasIndexedPoints) {
                    lineOffset = Int(r.u16()); headerLength += 2
                }
                if division.hasAreas
                    && (division.hasPoints || division.hasIndexedPoints || division.hasLines) {
                    areaOffset = Int(r.u16()); headerLength += 2
                }
                if division.hasPoints {
                    pointEnd = division.hasIndexedPoints ? indexedOffset
                        : division.hasLines ? lineOffset
                        : division.hasAreas ? areaOffset : whole
                }
                if division.hasIndexedPoints {
                    indexedEnd = division.hasLines ? lineOffset
                        : division.hasAreas ? areaOffset : whole
                }
                if division.hasLines { lineEnd = division.hasAreas ? areaOffset : whole }
                if division.hasAreas { areaEnd = whole }
            }
        }

        private func points(_ r: inout Bytes, _ division: Subdivision, until end: Int,
                            tile: String,
                            emit: (ElementDumper.Kind, Int, [Coord]) throws -> Void) throws {
            while r.position < end {
                guard r.position + 8 <= data.count else {
                    throw Trouble.malformed(tile, "point past the end of RGN")
                }
                var type = Int(r.u8()) << 8
                let value = Int(r.u24())
                let hasSubtype = value & 0x800000 != 0
                let dLon = Int32(r.s16()), dLat = Int32(r.s16())
                if hasSubtype { type |= Int(r.u8()) }
                try emit(.point, type, [Coord(lat: division.lat &+ (dLat << Int32(division.shift)),
                                              lon: division.lon &+ (dLon << Int32(division.shift)))])
            }
        }

        private func extendedPoint(_ r: inout Bytes, _ division: Subdivision, tile: String,
                                   emit: (ElementDumper.Kind, Int, [Coord]) throws -> Void) throws {
            guard r.position + 6 <= data.count else {
                throw Trouble.malformed(tile, "extended point past the end of RGN")
            }
            var type = Int(r.u8()) << 8
            let b = Int(r.u8())
            type |= 0x10000 + (b & 0x1f)
            let dLon = Int32(r.s16()), dLat = Int32(r.s16())
            if b & 0x20 != 0 { _ = r.u24() }
            if b & 0x80 != 0 { try skipExtraBytes(&r, tile: tile) }
            try emit(.point, type, [Coord(lat: division.lat &+ (dLat << Int32(division.shift)),
                                          lon: division.lon &+ (dLon << Int32(division.shift)))])
        }

        /// A classic polyline or polygon record.
        private func line(_ r: inout Bytes, _ division: Subdivision, polygon: Bool,
                          tile: String, into coords: inout [Coord]) throws -> Int {
            guard r.position + 9 <= data.count else {
                throw Trouble.malformed(tile, "line past the end of RGN")
            }
            let head = Int(r.u8())
            let type = polygon ? head & 0x7f : head & 0x3f
            let label = Int(r.u24())
            // The extra bit: one flag per vertex in the bit stream, for lines.
            let extra = label & 0x400000 != 0
            let dLon = Int32(r.s16()), dLat = Int32(r.s16())
            let length = head & 0x80 == 0 ? Int(r.u8()) : Int(r.u16())
            let base = Int(r.u8())
            guard r.position + length <= data.count else {
                throw Trouble.malformed(tile, "bit stream past the end of RGN")
            }
            let stream = r.take(length)
            bitStream(from: stream, base: base, length: length, shift: division.shift,
                      start: Coord(lat: division.lat &+ (dLat << Int32(division.shift)),
                                   lon: division.lon &+ (dLon << Int32(division.shift))),
                      extra: extra, extended: false, polygon: polygon, into: &coords)
            return type
        }

        /// An extended-type polyline or polygon record.
        private func extendedLine(_ r: inout Bytes, _ division: Subdivision, polygon: Bool,
                                  tile: String, into coords: inout [Coord]) throws -> Int {
            guard r.position + 8 <= data.count else {
                throw Trouble.malformed(tile, "extended line past the end of RGN")
            }
            var type = Int(r.u8()) << 8
            let b1 = Int(r.u8())
            let hasExtraBytes = b1 & 0x80 != 0
            let hasLabel = b1 & 0x20 != 0
            type |= 0x10000 + (b1 & 0x1f)
            let dLon = Int32(r.s16()), dLat = Int32(r.s16())
            let l1 = Int(r.u8())
            var length: Int
            if l1 & 0x01 != 0 {
                length = (l1 >> 1) & 0x7f
            } else {
                let l2 = Int(r.u8())
                length = ((l2 << 8) + l1) >> 2
            }
            length -= 1   // the encoded value includes the base byte
            guard length > 0 else { throw Trouble.malformed(tile, "empty extended bit stream") }
            let base = Int(r.u8())
            guard r.position + length <= data.count else {
                throw Trouble.malformed(tile, "bit stream past the end of RGN")
            }
            let stream = r.take(length)
            bitStream(from: stream, base: base, length: length, shift: division.shift,
                      start: Coord(lat: division.lat &+ (dLat << Int32(division.shift)),
                                   lon: division.lon &+ (dLon << Int32(division.shift))),
                      extra: false, extended: true, polygon: polygon, into: &coords)
            if hasLabel { _ = r.u24() }
            if hasExtraBytes { try skipExtraBytes(&r, tile: tile) }
            return type
        }

        /// The attribute bytes an extended element may carry after its geometry — read
        /// past, the way mkgmap reads them, because their length is in their first byte.
        private func skipExtraBytes(_ r: inout Bytes, tile: String) throws {
            guard r.position < data.count else { throw Trouble.malformed(tile, "extra bytes past the end") }
            let b1 = r.u8()
            if b1 & 0xe0 != 0 {
                // Varying length, ending on 0x01.
                var b: UInt8
                repeat {
                    guard r.position < data.count else { throw Trouble.malformed(tile, "extra bytes past the end") }
                    b = r.u8()
                } while b != 0x01
            } else if b1 & 0xa0 != 0 {
                _ = r.u8(); _ = r.u8()
            } else if b1 & 0x80 != 0 {
                _ = r.u8()
            }
        }

        /// The deltas of a line, unpacked into vertices: the same-sign flags, the widths
        /// taken from the base byte, the escape a signed delta uses to say "add another",
        /// the trailing zero pair that is padding, and the closing vertex of a polygon.
        private func bitStream(from offset: Int, base: Int, length: Int,
                               shift: Int, start: Coord, extra: Bool, extended: Bool,
                               polygon: Bool, into out: inout [Coord]) {
            out.removeAll(keepingCapacity: true)
            out.append(start)
            guard length > 0 else { return }
            var xbase = 2
            var n = base & 0xf
            xbase += n <= 9 ? n : 2 * n - 9
            n = (base >> 4) & 0xf
            var ybase = 2
            ybase += n <= 9 ? n : 2 * n - 9

            var bits = BitReader(data.bytes, from: offset)
            var xneg = false
            let xsame = bits.get1()
            if xsame { xneg = bits.get1() } else { xbase += 1 }
            var yneg = false
            let ysame = bits.get1()
            if ysame { yneg = bits.get1() } else { ybase += 1 }
            if extended { _ = bits.get1() }
            if extra { _ = bits.get1() }

            var lat = start.lat, lon = start.lon
            let need = (extra ? 1 : 0) + xbase + ybase
            while bits.position <= 8 * length - need {
                var dx: Int
                if xsame {
                    dx = bits.get(xbase)
                    if xneg { dx = -dx }
                } else {
                    dx = bits.sget2(xbase)
                }
                var dy: Int
                if ysame {
                    dy = bits.get(ybase)
                    if yneg { dy = -dy }
                } else {
                    dy = bits.sget2(ybase)
                }
                var isNode = false
                if extra { isNode = bits.get1() }
                // Some zero bits at the end of the stream would read as one more vertex.
                if !isNode && dx == 0 && dy == 0 { continue }
                lat = lat &+ Int32(truncatingIfNeeded: dy << shift)
                lon = lon &+ Int32(truncatingIfNeeded: dx << shift)
                out.append(Coord(lat: lat, lon: lon))
            }
            if polygon { out.append(out[0]) }
        }
    }
}
