import Foundation

/// Finding TYPs worth borrowing: the Garmin folders of home and every mounted volume.
extension TypLibrary {
    // MARK: Finding things to import

    /// Where to look for TYPs worth borrowing: the Garmin folder of the home directory
    /// and of every mounted volume, which directories count as mounted being answered
    /// per platform. The library is the destination, not a source, and is excluded.
    static func searchRoots(volumes: [URL] = Platform.mountedVolumes()) -> [URL] {
        var roots = [Paths.home.appendingPathComponent("Garmin", isDirectory: true)]
        for volume in volumes {
            roots.append(volume.appendingPathComponent("Garmin", isDirectory: true))
        }
        return roots.filter { FileTools.exists($0) }
    }

    /// Where `discover` looks unless told: nowhere in a test run, which has no business
    /// with the machine's drives, as `Paths.root` keeps it off the real settings.
    static var defaultSearchRoots: [URL] { Paths.isATestRun ? [] : searchRoots() }

    /// Walks `roots` for anything holding a TYP. Blocking and slow - by default it reaches
    /// into every Garmin folder on every volume - so call it off the render loop.
    /// - Parameter excluding: kmap's own output folder, which is skipped.
    static func discover(in roots: [URL] = defaultSearchRoots, excluding output: URL?) -> [TypCandidate] {
        var found: [TypCandidate] = []
        var seenProducts = Set<String>()
        let outputPath = output.map { $0.standardizedFileURL.path + "/" }

        for root in roots {
            for url in files(under: root, excludingPrefix: outputPath) {
                let extensionName = url.pathExtension.lowercased()
                let folder = url.deletingLastPathComponent().lastPathComponent

                if extensionName == "typ" {
                    guard let info = TypInfo.read(url) else { continue }
                    found.append(
                        TypCandidate(
                            url: url,
                            isEmbedded: false,
                            familyID: info.familyID,
                            productID: info.productID,
                            size: FileTools.size(of: url),
                            name: url.deletingPathExtension().lastPathComponent,
                            location: folder,
                            fingerprint: fingerprint(ofTypAt: url)
                        )
                    )
                } else if extensionName == "img" {
                    guard let identity = ImgContainer.typIdentity(in: url) else { continue }
                    // One entry per product: a split map carries the same TYP in both
                    // halves, and a product folder holds hundreds of tiles that all do.
                    let key = "\(identity.familyID)-\(identity.productID)-\(identity.size)"
                    guard seenProducts.insert(key).inserted else { continue }
                    // Fingerprinted only after the cheap key has dropped the duplicates:
                    // reading tens of kilobytes from every tile of a folder is slow.
                    found.append(
                        TypCandidate(
                            url: url,
                            isEmbedded: true,
                            familyID: identity.familyID,
                            productID: identity.productID,
                            size: Int64(identity.size),
                            name: folder,
                            location: url.lastPathComponent,
                            fingerprint: fingerprint(ofTypAt: url)
                        )
                    )
                }
            }
        }
        return found.sorted {
            ($0.name.lowercased(), $0.familyID) < ($1.name.lowercased(), $1.familyID)
        }
    }

    /// The TYPs and maps within 3 levels of `root`. A walk of its own: on Windows the
    /// enumerator's `skipDescendants` also stops it entering every later folder.
    private static func files(under root: URL, excludingPrefix output: String?) -> [URL] {
        var out: [URL] = []
        func walk(_ dir: URL, depth: Int) {
            let entries =
                (try? FileManager.default.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
            for url in entries {
                if out.count > 400 { return }
                if let output, url.standardizedFileURL.path.hasPrefix(output) { continue }
                if isDirectory(url) {
                    // A .gmap bundle holds hundreds of per-tile files and a TYP that also
                    // exists as a plain .typ beside it. kmap's own output, wherever it was
                    // put, leaves a build-info.txt beside its .img, which the configured
                    // folder alone misses.
                    guard depth < 3, url.pathExtension.lowercased() != "gmap", !isPackage(url),
                        !FileTools.exists(url.appendingPathComponent("build-info.txt"))
                    else { continue }
                    walk(url, depth: depth + 1)
                } else if ["typ", "img"].contains(url.pathExtension.lowercased()) {
                    out.append(url)
                }
            }
        }
        walk(root, depth: 1)
        return out
    }

    /// An application or other bundle, which the Mac shows as a file.
    private static func isPackage(_ url: URL) -> Bool {
        #if canImport(Darwin)
        (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
        #else
        false
        #endif
    }
}
