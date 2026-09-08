import Foundation

/// A path in the platform's own file-system spelling.
///
/// `URL.path` is POSIX-shaped, so on Windows it yields `/E:/dir/file` rather than a path
/// any program there can open. On the Unixes it equals `.path` byte for byte.
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
