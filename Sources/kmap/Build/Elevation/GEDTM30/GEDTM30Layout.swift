import Foundation

// MARK: The layout

extension GEDTM30 {
    /// What the first image of the file says about itself, and where its tile index is.
    struct Layout: Sendable {
        let width: Int
        let height: Int
        let tileWidth: Int
        let tileHeight: Int
        let bigEndian: Bool
        let predictor: Int
        let offsetsAt: Int64
        let offsetSize: Int
        let countsAt: Int64
        let countSize: Int
        let tileCount: Int
        /// Where the centre of pixel (0, 0) is, and the pixel size, in degrees.
        let firstLon: Double
        let firstLat: Double
        let step: Double
        let nodata: Float?

        var tilesAcross: Int { (width + tileWidth - 1) / tileWidth }

        /// How a tile holds its samples: 32-bit floats.
        var tile: GeoTIFF.Block {
            GeoTIFF.Block(
                width: tileWidth,
                height: tileHeight,
                bytesPerSample: 4,
                sampleFormat: TIFF.SampleFormat.float,
                predictor: predictor,
                bigEndian: bigEndian
            )
        }

        /// The pixel holding the cell's north-west node. Nodes go 1 pixel per arc-second
        /// from there, east and south.
        func corner(lat: Int, lon: Int) throws -> (row: Int, column: Int) {
            let column = (Double(lon) - firstLon) / step
            let row = (firstLat - Double(lat + 1)) / step
            guard abs(column - column.rounded()) < 0.01, abs(row - row.rounded()) < 0.01 else {
                throw Trouble.unsupported("pixel centres off the arc-second grid")
            }
            return (Int(row.rounded()), Int(column.rounded()))
        }

        /// The tiles a cell's nodes fall in, row by row of tiles. None unless the raster
        /// holds every node: a cell cut by its edge (85N, 65S) is left to later sources.
        func tiles(lat: Int, lon: Int, nodes: Int) throws -> [Int] {
            let (row, column) = try corner(lat: lat, lon: lon)
            guard row >= 0, column >= 0, row + nodes <= height, column + nodes <= width else { return [] }
            var out: [Int] = []
            for tileRow in (row / tileHeight)...((row + nodes - 1) / tileHeight) {
                for tileColumn in (column / tileWidth)...((column + nodes - 1) / tileWidth) {
                    out.append(tileRow * tilesAcross + tileColumn)
                }
            }
            return out
        }
    }

    /// A tile side past this means a damaged header.
    private static let largestTileSide = 4096

    /// Reads the header and the first image's tags, BigTIFF or classic.
    static func layout(read: @escaping Read) async throws -> Layout {
        let tags = try await Directory(read: read)

        let compression = try await tags.one(TIFF.Tag.compression)
        guard compression == TIFF.Compression.deflate || compression == TIFF.Compression.adobeDeflate else {
            throw Trouble.unsupported("compression")
        }
        guard try await tags.one(TIFF.Tag.bitsPerSample) == 32,
            try await tags.one(TIFF.Tag.sampleFormat, TIFF.SampleFormat.unsigned) == TIFF.SampleFormat.float
        else {
            throw Trouble.unsupported("samples other than float32")
        }
        guard try await tags.one(TIFF.Tag.samplesPerPixel, 1) == 1 else { throw Trouble.unsupported("several bands") }
        let predictor = try await tags.one(TIFF.Tag.predictor, TIFF.Predictor.none)
        guard predictor == TIFF.Predictor.none || predictor == TIFF.Predictor.horizontal else {
            throw Trouble.unsupported("predictor \(predictor)")
        }
        let offsets = try tags.index(TIFF.Tag.tileOffsets), counts = try tags.index(TIFF.Tag.tileByteCounts)
        guard offsets.count == counts.count else { throw Trouble.notTIFF }

        let scale = try await tags.numbers(TIFF.Tag.modelPixelScale)
        let tie = try await tags.numbers(TIFF.Tag.modelTiepoint)
        guard scale.count >= 2, tie.count >= 6, scale[0] > 0, abs(scale[0] - scale[1]) < 1e-12,
            abs(scale[0] * Double(HGTConversion.arcSecondsPerDegree) - 1) < 1e-6
        else { throw Trouble.unsupported("not 1 arc-second") }
        // The tiepoint is a pixel's corner unless the file says it is its centre.
        let keys = try await tags.numbers(TIFF.Tag.geoKeyDirectory)
        let half = TIFF.rasterType(in: keys) == TIFF.RasterType.point ? 0 : 0.5

        let width = try await tags.one(TIFF.Tag.imageWidth), height = try await tags.one(TIFF.Tag.imageLength)
        let tileWidth = try await tags.one(TIFF.Tag.tileWidth)
        let tileHeight = try await tags.one(TIFF.Tag.tileLength)
        let sides = 1...largestTileSide
        guard width > 0, height > 0, sides.contains(tileWidth), sides.contains(tileHeight),
            offsets.count == ((width + tileWidth - 1) / tileWidth) * ((height + tileHeight - 1) / tileHeight)
        else { throw Trouble.unsupported("tile grid") }
        return Layout(
            width: width,
            height: height,
            tileWidth: tileWidth,
            tileHeight: tileHeight,
            bigEndian: tags.order.bigEndian,
            predictor: predictor,
            offsetsAt: offsets.at,
            offsetSize: offsets.size,
            countsAt: counts.at,
            countSize: counts.size,
            tileCount: offsets.count,
            firstLon: tie[3] + (half - tie[0]) * scale[0],
            firstLat: tie[4] - (half - tie[1]) * scale[1],
            step: scale[0],
            nodata: try await tags.text(TIFF.Tag.gdalNodata).flatMap { Float($0) }
        )
    }

    /// The first image's tags, their values fetched as they are asked for.
    private struct Directory {
        /// A tag read whole is short; a longer one means a damaged header.
        private static let longestValue = 65536
        /// More entries than this is not a directory.
        private static let mostEntries = 1000
        /// More tiles than this is not an index.
        private static let mostTiles = 1 << 24

        let order: TIFF.Order
        private let read: Read
        private let table: Data
        /// Bytes of an entry's field: the value itself when it fits, else its offset.
        private let fieldSize: Int
        private let entries: [Int: (type: Int, count: Int, field: Int)]

        init(read: @escaping Read) async throws {
            let head = try await read(0, 16)
            guard head.count >= 16, let bigEndian = TIFF.isBigEndian(head[head.startIndex], head[head.startIndex + 1])
            else { throw Trouble.notTIFF }
            let order = TIFF.Order(bigEndian: bigEndian)
            let version = order.int(head, 2, 2)
            guard version == TIFF.classic || version == TIFF.big else { throw Trouble.notTIFF }
            let big = version == TIFF.big
            let at = Int64(big ? order.int(head, 8, 8) : order.int(head, 4, 4))
            let countSize = big ? 8 : 2, entrySize = big ? 20 : 12
            let count = order.int(try await read(at, countSize), 0, countSize)
            guard count > 0, count < Self.mostEntries else { throw Trouble.notTIFF }
            let table = try await read(at + Int64(countSize), count * entrySize)
            guard table.count == count * entrySize else { throw Trouble.notTIFF }

            var entries: [Int: (type: Int, count: Int, field: Int)] = [:]
            for i in 0..<count {
                let entry = i * entrySize
                entries[order.int(table, entry, 2)] = (
                    order.int(table, entry + 2, 2),
                    order.int(table, entry + 4, big ? 8 : 4),
                    entry + (big ? 12 : 8)
                )
            }
            self.order = order
            self.read = read
            self.table = table
            self.entries = entries
            fieldSize = big ? 8 : 4
        }

        /// The value's bytes, inline or fetched from where the field points.
        private func raw(_ tag: Int) async throws -> (type: Int, count: Int, data: Data)? {
            guard let entry = entries[tag] else { return nil }
            guard entry.count >= 0, entry.count <= Self.longestValue else { throw Trouble.notTIFF }
            let length = TIFF.size(ofType: entry.type) * entry.count
            let data =
                length <= fieldSize
                ? table.subdata(in: (table.startIndex + entry.field)..<(table.startIndex + entry.field + length))
                : try await read(Int64(order.int(table, entry.field, fieldSize)), length)
            guard data.count >= length else { throw Trouble.notTIFF }
            return (entry.type, entry.count, data)
        }

        func numbers(_ tag: Int) async throws -> [Double] {
            guard let (type, count, data) = try await raw(tag) else { return [] }
            let size = TIFF.size(ofType: type)
            return (0..<count).compactMap { order.number(data, $0 * size, type: type) }
        }

        /// A whole number; `fallback` where the file has no such tag.
        func one(_ tag: Int, _ fallback: Int? = nil) async throws -> Int {
            if let value = try await numbers(tag).first {
                guard let whole = Int(exactly: value) else { throw Trouble.notTIFF }
                return whole
            }
            guard let fallback else { throw Trouble.unsupported("no tag \(tag)") }
            return fallback
        }

        /// A text tag up to its first 0 byte, trimmed.
        func text(_ tag: Int) async throws -> String? {
            guard let (_, _, data) = try await raw(tag) else { return nil }
            return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }

        /// Where a tile index starts, its entry size and count. Too long to fetch whole.
        func index(_ tag: Int) throws -> (at: Int64, size: Int, count: Int) {
            guard let entry = entries[tag], entry.type == TIFF.FieldType.long || entry.type == TIFF.FieldType.long8
            else { throw Trouble.unsupported("tile index tag \(tag)") }
            guard entry.count > 1, entry.count <= Self.mostTiles else { throw Trouble.unsupported("tile count") }
            return (Int64(order.int(table, entry.field, fieldSize)), TIFF.size(ofType: entry.type), entry.count)
        }
    }
}
