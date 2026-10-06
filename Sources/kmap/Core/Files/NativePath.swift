import Foundation

/// A path in the platform's own spelling: on Windows `URL.path` gives `E:/dir/file` with
/// forward slashes; on the Unixes this equals `.path`.
extension URL {
    /// This file's path in the platform's file-system spelling.
    ///
    /// Required wherever a path leaves kmap: child-process arguments, files other tools
    /// read back, text shown to a person. `.path` remains correct inside Foundation.
    var nativePath: String {
        withUnsafeFileSystemRepresentation { pointer in
            // Nil only for a non-file URL.
            guard let pointer else { return path }
            return String(cString: pointer)
        }
    }
}
