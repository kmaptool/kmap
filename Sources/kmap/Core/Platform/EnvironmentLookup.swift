import Foundation

/// Environment lookup that follows the platform's own name matching.
///
/// Windows environment names are case-insensitive and Swift's dictionary is not; on the
/// Unixes names are case-sensitive, so the match stays exact there.
extension Dictionary where Key == String, Value == String {

    /// The value of `name`, matched the way this machine matches variable names.
    func variable(_ name: String,
                  on platform: Platform = Platform.current) -> String? {
        if let exact = self[name] { return exact }
        guard platform.usesWindowsPaths else { return nil }
        let wanted = name.lowercased()
        return first { $0.key.lowercased() == wanted }?.value
    }
}
