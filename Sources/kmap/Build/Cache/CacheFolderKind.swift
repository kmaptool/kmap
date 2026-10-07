import Foundation

/// What a cache folder holds of kmap's, and so which names in it are kmap's.
enum CacheFolderKind {
    /// The elevation cache's top: its indexes.
    case elevationTop
    /// A source folder: tiles and their marks.
    case source
    /// Viewfinder's source folders: tiles, and the archives being fetched and unpacked.
    case viewfinder
    /// GeoTIFFs waiting to become tiles.
    case tifs
    /// GEDTM30's chunks.
    case chunks
    /// The extract cache.
    case extracts
}
