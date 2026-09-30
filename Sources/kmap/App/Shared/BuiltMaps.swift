import Foundation

/// The maps a build leaves in the output folder: card files and BaseCamp folders, in the
/// folder itself and one level down, since each build writes into its own dated folder.
enum BuiltMaps {
    static let extensions = ["img", "gmap"]

    static func outputs(under root: URL) -> [URL] {
        func outputs(in dir: URL) -> [URL] {
            extensions.flatMap { FileTools.contents(of: dir, extension: $0) }
        }
        var found = outputs(in: root)
        for entry in FileTools.contents(of: root)
        where entry.pathExtension.lowercased() != "gmap" && FileTools.isDirectory(entry) {
            found.append(contentsOf: outputs(in: entry))
        }
        return found
    }
}
