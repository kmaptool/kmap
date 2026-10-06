import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where a region's extract is to be had right now.
struct ExtractSource {
    /// The file to fetch: the mirror's `-latest` name, or a dated file standing in.
    let url: URL
    /// Its published checksum.
    let md5: URL?
    let info: Downloader.RemoteInfo
    /// The dated file's name, where `-latest` was not being served.
    let standIn: String?
}
