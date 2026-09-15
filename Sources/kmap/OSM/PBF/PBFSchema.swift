import Foundation

/// Field numbers from the OSM PBF schema, and the units the format fixes.
enum PBFSchema {
    static let blobHeaderKind = 1, blobHeaderSize = 3
    static let blobRaw = 1, blobRawSize = 2, blobZlib = 3
    static let blobLzma = 4, blobLz4 = 6, blobZstd = 7
    static let stringTable = 1, primitiveGroup = 2
    static let granularity = 17, latOffset = 19, lonOffset = 20
    static let headerBBox = 1, headerRequiredFeature = 4, headerWritingProgram = 16
    static let bboxLeft = 1, bboxRight = 2, bboxTop = 3, bboxBottom = 4
    static let groupDense = 2, groupWays = 3, groupRelations = 4
    static let denseID = 1, denseLat = 8, denseLon = 9, denseKeysVals = 10
    static let elementID = 1, elementKeys = 2, elementVals = 3
    static let wayRefs = 8
    static let memberRoles = 8, memberIDs = 9, memberKinds = 10
    static let stringEntry = 1

    /// Blob kinds, as a BlobHeader names them.
    static let headerBlob = "OSMHeader", dataBlob = "OSMData"
    /// What a header of kmap's own declares.
    static let requiredFeatures = ["OsmSchema-V0.6", "DenseNodes"]
    static let writingProgram = "kmap"

    /// The big-endian length in front of every blob header.
    static let lengthPrefix = MemoryLayout<UInt32>.size
    /// The format's ceiling on one blob's uncompressed size.
    static let maxUncompressedBlob = 32 << 20

    /// Nanodegrees, the unit of a header bounding box.
    static let bboxScale = 1e9
    /// The default granularity: one stored unit is 1e-7 of a degree.
    static let coordinateScale = 1e7
}
