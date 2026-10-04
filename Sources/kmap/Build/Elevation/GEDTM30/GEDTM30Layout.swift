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
}
