import Foundation

/// Where styles are built and swapped into place, under the styles lock.
extension StyleCatalog {
    /// Runs `body` with the styles directory held against other kmap processes.
    ///
    /// The lock is advisory and process-wide; the only writer is style materialization.
    func holdingStyles<T>(_ body: () throws -> T) rethrows -> T {
        Paths.ensure(Paths.styles)
        return try FileLock.holding(Paths.styles.appendingPathComponent(".lock"), body)
    }

    /// A private copy of a prepared style, taken under the styles lock.
    ///
    /// mkgmap reads the style throughout its run, so a build must not read the shared
    /// directory, which a concurrent build may rewrite.
    ///
    /// - Returns: false where `expecting` is given and the copy carries another marker:
    ///   another build swapped the shared style since this one prepared it.
    @discardableResult
    func snapshot(_ directory: URL, to destination: URL, expecting: String? = nil) throws -> Bool {
        try holdingStyles {
            FileTools.removeIfPresent(destination)
            // The folder a link leads to: copied as a link, the build's rule edits would
            // write through it into the user's own files.
            do {
                try FileTools.copy(FileTools.resolvingLinks(directory), to: destination)
            } catch {
                // A copy cut short would be compiled as if it were the style.
                FileTools.removeIfPresent(destination)
                throw error
            }
            guard let expecting else { return true }
            let marker = try? String(contentsOf: destination.appendingPathComponent("kmap-version"), encoding: .utf8)
            return marker?.trimmingCharacters(in: .whitespacesAndNewlines) == expecting
        }
    }

    /// The marker the rules prepared for `style` with `choices` carry, for the styles kmap
    /// materializes into a shared folder; nil for one it does not.
    func expectedMarker(for style: MapStyle, choices: StyleChoices) -> String? {
        if style.styleDirectory == StyleCatalog.baseStyleDirectory { return materializedIdentity(choices) }
        guard case .importedTYP = style.origin, let typ = style.typURL,
            style.styleDirectory?.lastPathComponent.hasPrefix("recovered-") == true,
            let sheetURL = TypLibrary.sheet(of: typ),
            let sheet = try? String(contentsOf: sheetURL, encoding: .utf8)
        else { return nil }
        return materializedIdentity(choices, fittedToLadder: true)
            + "+sheet-\(TypLibrary.fingerprint(Data(sheet.utf8)))"
    }

    /// What a killed run left: hidden build folders and unpackings a day old, so none another
    /// kmap is filling now, and rule sets a swap set aside, settled under the styles lock.
    static func removeAbandonedStaging(in styles: URL = Paths.styles, now: Date = Date()) {
        let entries = (try? FileManager.default.contentsOfDirectory(at: styles, includingPropertiesForKeys: nil)) ?? []
        FileLock.holding(styles.appendingPathComponent(".lock")) {
            for entry in entries where isSwappedOut(entry.lastPathComponent) {
                let original = entry.deletingLastPathComponent()
                    .appendingPathComponent(String(entry.lastPathComponent.dropFirst().dropLast(".old".count)))
                if FileTools.exists(original) {
                    FileTools.removeIfPresent(entry)
                } else {
                    try? FileTools.move(entry, to: original)
                }
            }
        }
        for entry in entries {
            let name = entry.lastPathComponent
            guard
                (name.hasPrefix(".") && name.contains("-build-")) || isUnpacking(name)
                    || name.hasPrefix(".hideable-"),
                let changed = FileTools.modified(of: entry), now.timeIntervalSince(changed) > 86_400
            else { continue }
            FileTools.removeIfPresent(entry)
        }
    }

    /// A directory to build a style in before it is swapped into place. Hidden, so the
    /// style list, which takes any folder holding a `lines` file, does not show it.
    static func stagingDirectory(for what: String) -> URL {
        Paths.ensure(Paths.styles)
        return Paths.styles.appendingPathComponent(
            ".\(what)-build-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
    }

    /// Puts a finished build where the style lives, in one step.
    ///
    /// The marker is written before the swap, so `dir` holds either a complete stamped
    /// style or the previous one.
    func install(_ build: URL, as dir: URL, marker wanted: String) throws {
        try FileTools.write(wanted, to: build.appendingPathComponent("kmap-version"))
        try holdingStyles {
            // A folder without kmap's marker is the user's, named like a recovered style.
            if dir.lastPathComponent.hasPrefix("recovered-"), FileTools.exists(dir),
                !FileTools.exists(dir.appendingPathComponent("kmap-version"))
            {
                throw StyleError.usersOwnFolder(Paths.display(dir))
            }
            try FileTools.replace(dir, with: build, aside: Self.swappedOut)
        }
    }

    /// Where a swap keeps the rule set it replaces: hidden, so it is never listed, and
    /// never a name a user's own folder has.
    static func swappedOut(_ dir: URL) -> URL {
        dir.deletingLastPathComponent().appendingPathComponent(".\(dir.lastPathComponent).old", isDirectory: true)
    }

    /// Whether `dir` already holds a style stamped `wanted`, read under the lock so a
    /// swap in progress is seen either whole or not at all.
    func isMaterialized(_ dir: URL, as wanted: String) -> Bool {
        let marker = dir.appendingPathComponent("kmap-version")
        let current = holdingStyles { try? String(contentsOf: marker, encoding: .utf8) }
        return current?.trimmingCharacters(in: .whitespacesAndNewlines) == wanted
            && FileTools.exists(dir.appendingPathComponent("lines"))
    }
}
