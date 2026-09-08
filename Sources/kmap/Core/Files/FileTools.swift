import Foundation
#if os(Windows)
import WinSDK
#endif

enum FileTools {
    static func size(of url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attrs[.size] as? NSNumber else { return 0 }
        return number.int64Value
    }

    static func modified(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Whether `path` names a program this machine could run.
    ///
    /// Windows is asked through `GetFileAttributesW`: `isExecutableFile` there judges the
    /// extension and accepts non-existent paths, and `fileExists` rejects the app
    /// execution aliases, which are reparse points. `Platform.which` supplies the
    /// extension.
    static func isExecutable(_ path: String) -> Bool {
        #if os(Windows)
        let attributes = path.withCString(encodedAs: UTF16.self) { GetFileAttributesW($0) }
        guard attributes != INVALID_FILE_ATTRIBUTES else { return false }
        return attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0
        #else
        return FileManager.default.isExecutableFile(atPath: path)
        #endif
    }

    /// Files directly inside `dir`, optionally filtered by extension, sorted by name.
    static func contents(of dir: URL, extension ext: String? = nil) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        let filtered = ext.map { e in
            items.filter { $0.pathExtension.lowercased() == e.lowercased() }
        } ?? items
        return filtered.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Every file anywhere under `dir`, optionally filtered by extension, sorted by name.
    ///
    /// For archives whose internal layout is not known in advance, with or without
    /// intermediate folders.
    static func allFiles(under dir: URL, extension ext: String? = nil) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            if let ext, url.pathExtension.lowercased() != ext.lowercased() { continue }
            out.append(url)
        }
        return out.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func removeIfPresent(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Empties a directory without removing the directory itself.
    static func emptyDirectory(_ url: URL) {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil) else { return }
        for item in items { try? FileManager.default.removeItem(at: item) }
    }

    /// Bytes free on the volume holding `url`, or zero where the system will not say.
    ///
    /// Uses important-usage capacity on Darwin, which counts purgeable space a large
    /// write would reclaim; that key is absent from `URLResourceKey` elsewhere.
    static func freeSpaceBytes(at url: URL) -> Int64 {
        #if canImport(Darwin)
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage else { return 0 }
        return capacity
        #else
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
              let capacity = values.volumeAvailableCapacity else { return 0 }
        return Int64(capacity)
        #endif
    }

    /// A filesystem-safe token derived from a region id: anything outside letters,
    /// digits, `-` and `_` becomes a hyphen, and the result is lowercased.
    static func slugify(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(mapped)
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .lowercased()
    }
}
