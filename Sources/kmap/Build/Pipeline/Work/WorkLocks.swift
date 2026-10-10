import Foundation

extension BuildPipeline {
    /// Held for the whole build: 2 builds of 1 region share its work folder. Kept among
    /// kmap's locks, where locking works, not in a work folder on a network share.
    var buildLock: URL { Self.lock(Self.workLockPrefix, for: workDirectory) }

    /// 2 builds with their own work folders may still share the output folder.
    var outputLock: URL { Self.lock(Self.outputLockPrefix, for: recipe.destinationDirectory) }

    static let workLockPrefix = "work-"
    static let outputLockPrefix = "output-"

    /// Keyed by the folder itself: past links, and case-folded where the volume ignores case.
    static func lock(_ prefix: String, for folder: URL) -> URL {
        var path = resolvedPath(folder)
        #if os(Linux)
        // A Windows drive under WSL ignores case, as Windows does.
        if Platform.current.isWSL, path.hasPrefix("/mnt/") { path = path.lowercased() }
        #else
        path = path.lowercased()
        #endif
        return Paths.locks.appendingPathComponent(
            "\(prefix)\(String(TypLibrary.fingerprint(Data(path.utf8)), radix: 16)).lock"
        )
    }

    /// Resolved from the nearest existing folder, so a folder not made yet reads as it will
    /// once made. On Windows also past `subst` and mapped drives.
    static func resolvedPath(_ url: URL) -> String {
        let head = nearestPresent(url)
        let tail = Array(url.standardizedFileURL.pathComponents.dropFirst(head.pathComponents.count))
        #if os(Windows)
        if let final = Win32File.finalPath(of: head.nativePath) {
            // A drive's root comes with its separator: `D:\` and `D:\maps` alike.
            let trimmed = final.hasSuffix("\\") ? String(final.dropLast()) : final
            return ([trimmed] + tail).joined(separator: "\\")
        }
        #endif
        var resolved = FileTools.resolvingLinks(head)
        for part in tail { resolved.appendPathComponent(part) }
        return resolved.path
    }

    static func nearestPresent(_ url: URL) -> URL {
        var head = url.standardizedFileURL
        while !FileTools.exists(head), head.pathComponents.count > 1 { head = head.deletingLastPathComponent() }
        return head
    }

    /// Folder and download locks of past days; a held one stays, and kmap's fixed locks
    /// are not touched.
    static func removeOldLocks(in locks: URL = Paths.locks, now: Date = Date()) {
        let entries = (try? FileManager.default.contentsOfDirectory(at: locks, includingPropertiesForKeys: nil)) ?? []
        for entry in entries
        where [workLockPrefix, outputLockPrefix, "download-"].contains(where: { entry.lastPathComponent.hasPrefix($0) })
        {
            guard let changed = FileTools.modified(of: entry), now.timeIntervalSince(changed) > 2 * 86_400 else {
                continue
            }
            // Taking a lock refreshes its time, so this one is unused. One refused by rights
            // is another user's leftover and goes too. Asked without binding it, so
            // `held = nil` releases it.
            var held = HeldLock(trying: entry)
            guard held?.isHeld == true || held?.refused == true else { continue }
            #if os(Windows)
            // Let go first: Windows removes no file held open.
            held = nil
            FileTools.removeIfPresent(entry)
            #else
            // Gone while still held, so no one locks the old file in between.
            FileTools.removeIfPresent(entry)
            held = nil
            #endif
        }
    }
}
