import Foundation

extension BuildPipeline {
    /// So a work folder inside one the user chose can be swept.
    static let workMarker = ".kmap-work"
    /// Work files kept on purpose, which no sweep takes.
    static let keptMarker = ".kmap-kept"
    /// A sweep renames a folder to this prefix before removing it, so the lock is held only
    /// a moment.
    static let sweptPrefix = ".kmap-swept-"

    /// What kmap puts in a work folder, to recognise one left without the mark.
    private static let workEntries: Set<String> = [
        "build", "tiles", "style", "typ", "contours", "dem-cells", "hgt-peaks", "elevation-clip.poly", "dem-clip.poly",
        "copyright.txt",
        workMarker, keptMarker
    ]

    private static let browserLeftovers: Set<String> = [".DS_Store", "Thumbs.db", "desktop.ini"]

    /// Marked, empty (cut short before its mark), or unmarked with only what kmap puts
    /// there and something only kmap makes.
    static func isKmapsWork(_ folder: URL) -> Bool {
        guard FileTools.isDirectoryItself(folder) else { return false }
        if FileTools.exists(folder.appendingPathComponent(workMarker)) { return true }
        guard let all = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return false }
        let names = all.filter { !browserLeftovers.contains($0) && !$0.hasPrefix("._") }
        func annotated(_ name: String) -> Bool { name.hasPrefix("annotated") && name.hasSuffix(".osm.pbf") }
        guard names.allSatisfy({ workEntries.contains($0) || annotated($0) }) else { return false }
        let contours =
            (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("contours").path)) ?? []
        let made =
            [
                "elevation-clip.poly", "tiles/areas.list", "tiles/template.args", "build/tiles/tiles.args"
            ].contains { FileTools.exists(folder.appendingPathComponent($0)) }
            || contours.contains(where: { isKmapsContour($0) || isKmapsContourPart($0) })
        return names.isEmpty || made || names.contains(where: annotated)
    }

    /// `contour0001.osm.pbf`, as kmap names a cell's contours.
    private static func isKmapsContour(_ name: String) -> Bool {
        guard name.hasPrefix("contour"), name.hasSuffix(".osm.pbf") else { return false }
        let number = name.dropFirst("contour".count).dropLast(".osm.pbf".count)
        return number.count >= 4 && number.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// The same, cut short: `contour0003.osm.pbf.<hex>.partial`.
    private static func isKmapsContourPart(_ name: String) -> Bool {
        guard name.hasSuffix(".partial"), let pbf = name.range(of: ".osm.pbf.") else { return false }
        return isKmapsContour(String(name[..<pbf.upperBound].dropLast()))
    }

    static func isOwnWorkRoot(_ root: URL) -> Bool {
        var paths = [resolvedPath(root), resolvedPath(Paths.work)]
        #if !os(Linux)
        paths = paths.map { $0.lowercased() }
        #endif
        return paths[0] == paths[1]
    }

    /// This map's earlier work folder goes, failed or kept: every stage makes its files
    /// again. So do other maps' left over 3 days, unless work files are kept. Outside
    /// kmap's own root a folder goes only if it is kmap's work: one of the user's may have
    /// the same name.
    func clearEarlierWork(now: Date = Date()) throws {
        let ownRoot = Self.isOwnWorkRoot(recipe.workRoot)
        var freed: Int64 = 0
        if FileTools.exists(workDirectory) {
            guard ownRoot || Self.isKmapsWork(workDirectory) else {
                throw BuildError.workFolderNotKmaps(Paths.display(workDirectory))
            }
            freed += directorySize(workDirectory)
            FileTools.removeIfPresent(workDirectory)
        }
        // This map's folder under its name without the id mark (`areaSlug`), if kmap's, not
        // kept and not held.
        let unmarked = recipe.workRoot.appendingPathComponent(recipe.areaSlug, isDirectory: true)
        if recipe.slug != recipe.areaSlug, FileTools.exists(unmarked), Self.isKmapsWork(unmarked),
            !FileTools.exists(unmarked.appendingPathComponent(Self.keptMarker))
        {
            Paths.ensure(Paths.locks)
            var held = HeldLock(trying: Self.lock(Self.workLockPrefix, for: unmarked))
            if held?.isHeld == true {
                let size = directorySize(unmarked)
                if (try? FileTools.remove(unmarked)) != nil { freed += size }
            }
            held = nil
        }
        if !settings.settings.keepWorkFiles {
            freed += sweepAbandonedWork(now: now)
        }
        Paths.ensure(workDirectory)
        do {
            try FileTools.write("", to: workDirectory.appendingPathComponent(Self.workMarker))
        } catch {
            throw BuildError.workFolderUnwritable(Paths.display(workDirectory))
        }
        state.withLock { $0.madeWorkFolder = true }
        if freed > 0 { log.append("cleared \(Fmt.bytes(freed)) of work files left by earlier builds") }
    }

    /// Other maps' marked work folders, left over 3 days.
    private func sweepAbandonedWork(now: Date) -> Int64 {
        let root = recipe.workRoot
        var freed: Int64 = 0
        func abandoned(_ folder: URL) -> Bool {
            // By the mark alone: a guess could take a user's folder, or a kept one with no
            // kept mark.
            guard !FileTools.exists(folder.appendingPathComponent(Self.keptMarker)),
                let touched = FileTools.modified(of: folder.appendingPathComponent(Self.workMarker))
            else { return false }
            return now.timeIntervalSince(touched) > 3 * 86_400
        }
        for folder in FileTools.contents(of: root)
        where FileTools.isDirectoryItself(folder) && folder.lastPathComponent != workDirectory.lastPathComponent
            && abandoned(folder)
        {
            // Checked again and moved aside under the lock, removed after it: a build of
            // that map starting meanwhile is told another runs.
            let aside = root.appendingPathComponent(Self.sweptPrefix + UUID().uuidString.prefix(8))
            var held = HeldLock(trying: Self.lock(Self.workLockPrefix, for: folder))
            // Where locks do not work or the disk is too full for one, age alone decides.
            let moved = held != nil && abandoned(folder) && (try? FileTools.move(folder, to: aside)) != nil
            held = nil
            guard moved else { continue }
            freed += directorySize(aside)
            FileTools.removeIfPresent(aside)
        }
        // Left by a sweep stopped midway.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        where name.hasPrefix(Self.sweptPrefix) {
            let aside = root.appendingPathComponent(name)
            freed += directorySize(aside)
            FileTools.removeIfPresent(aside)
        }
        return freed
    }
}
