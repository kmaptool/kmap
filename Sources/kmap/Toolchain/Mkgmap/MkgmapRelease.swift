import Foundation

/// The mkgmap release kmap installs and builds its patch from, each download with its
/// SHA-256. The jar is run and the source compiled, so a file that does not match is
/// refused before it is unpacked. The patch's anchors are written against this revision.
extension Toolchain {
    struct PinnedDownload: Sendable {
        let file: String
        let sha256: String

        var url: URL? { URL(string: "https://www.mkgmap.org.uk/download/" + file) }
    }

    static let mkgmapRelease = PinnedDownload(
        file: "mkgmap-r4924.zip",
        sha256: "b2170799b61a95d4fc258e8e4fb4e21396809e0390789178f94c77109f8e0d84"
    )

    /// The source of each release the patch can be built for, by revision.
    static let mkgmapSources: [String: PinnedDownload] = [
        "4924": PinnedDownload(
            file: "mkgmap-r4924-src.zip",
            sha256: "6738fb14e5a6f5ab85b99445d82e0d162f51844c50052c71fd29387b3021cdbb"
        )
    ]

    /// Throws unless `file` is the pinned download.
    static func verify(_ file: URL, against pinned: PinnedDownload) throws {
        let digest = SHA256.hex(ofFileAt: file) ?? "unreadable"
        guard digest == pinned.sha256 else {
            throw InstallError.failed(t("%@ is not the file kmap knows (SHA-256 %@) — refused", pinned.file, digest))
        }
    }
}
