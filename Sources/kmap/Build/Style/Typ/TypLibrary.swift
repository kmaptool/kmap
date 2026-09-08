import Foundation

/// A TYP kmap could take a copy of.
enum TypLibrary {

    static var directory: URL { Paths.root.appendingPathComponent("typ", isDirectory: true) }

    /// Where builds used to drop TYPs lifted out of `.img` containers. Skipped when
    /// listing, and left in place: every file in it duplicates one in the folder above.
    static var legacyExtractedDirectory: URL {
        directory.appendingPathComponent("extracted", isDirectory: true)
    }

    // MARK: What is in the library

    /// Every TYP in the library, compiled or source, sorted by name.
    ///
    /// - Parameter directory: passed only by tests, to point at a throwaway folder.
    static func contents(in directory: URL = TypLibrary.directory) -> [URL] {
        let found = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        return found
            .filter { ["typ", "txt"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func holds(familyID: Int, productID: Int) -> Bool {
        contents().contains { url in
            guard let info = TypInfo.read(url) else { return false }
            return info.familyID == familyID && info.productID == productID
        }
    }

    // MARK: Writing

    /// True when a file is one kmap may write to, that is, one in the library. Every write
    /// goes through this: outside sit shipped products, the working copy of kmap's own TYP
    /// that every build rewrites from the embedded asset, and the asset itself.
    static func mayWrite(to url: URL, library: URL = TypLibrary.directory) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent().path
            == library.standardizedFileURL.path
    }

    /// Writes edited TYP source back over a library file.
    ///
    /// - Throws: `ImportError.failed` for any destination outside the library.
    static func save(_ text: String, to url: URL,
                     library: URL = TypLibrary.directory) throws {
        guard mayWrite(to: url, library: library) else {
            throw ImportError.failed(
                "\(Paths.display(url)) is outside kmap's TYP library, which is the only "
                + "place kmap writes a TYP — take an editable copy first")
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw ImportError.failed(error.localizedDescription)
        }
    }

    /// Puts TYP source into the library under a free name, and returns where it landed.
    /// Makes editable a style that cannot be edited where it lies, such as the built-in
    /// working copy, which every build rewrites from the embedded asset.
    @discardableResult
    static func adopt(source text: String, named name: String,
                      into directory: URL = TypLibrary.directory) throws -> URL {
        Paths.ensure(directory)
        let destination = freeName(FileTools.slugify(name), extension: "txt", in: directory)
        do {
            try text.write(to: destination, atomically: true, encoding: .utf8)
        } catch {
            throw ImportError.failed(error.localizedDescription)
        }
        return destination
    }

    // MARK: Managing what is in it

    /// Removes a style from the library, refusing anything outside it. Takes with it the
    /// untouched original kept beside a decompiled import and any recovered sheet, both
    /// of which exist only to serve this entry.
    static func delete(_ url: URL, library: URL = TypLibrary.directory) throws {
        guard mayWrite(to: url, library: library) else {
            throw ImportError.failed("\(Paths.display(url)) is not in kmap's TYP library")
        }
        guard FileTools.exists(url) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw ImportError.failed(error.localizedDescription)
        }
        let original = originalsDirectory(in: library)
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".typ")
        FileTools.removeIfPresent(original)
        if let kept = sheet(of: url, library: library) { FileTools.removeIfPresent(kept) }
    }

    /// Gives a style a different name, keeping its extension, and returns where it landed.
    /// The id is made from the name, so renaming changes it and a style that was the
    /// default stops being found by it.
    @discardableResult
    static func rename(_ url: URL, to name: String,
                       library: URL = TypLibrary.directory) throws -> URL {
        guard mayWrite(to: url, library: library) else {
            throw ImportError.failed("\(Paths.display(url)) is not in kmap's TYP library")
        }
        let base = FileTools.slugify(name)
        guard !base.isEmpty else { throw ImportError.failed("a style needs a name") }
        let destination = freeName(base, extension: url.pathExtension, in: library)
        guard destination != url else { return url }
        do {
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            throw ImportError.failed(error.localizedDescription)
        }
        // The kept original follows its source, so the pair stays a pair.
        let originals = originalsDirectory(in: library)
        let was = originals.appendingPathComponent(
            url.deletingPathExtension().lastPathComponent + ".typ")
        if FileTools.exists(was) {
            let now = originals.appendingPathComponent(
                destination.deletingPathExtension().lastPathComponent + ".typ")
            FileTools.removeIfPresent(now)
            try? FileManager.default.moveItem(at: was, to: now)
        }
        // The recovered sheet follows its source as well.
        if let kept = sheet(of: url, library: library) {
            let now = sheetsDirectory(in: library).appendingPathComponent(
                destination.deletingPathExtension().lastPathComponent + ".txt")
            FileTools.removeIfPresent(now)
            try? FileManager.default.moveItem(at: kept, to: now)
        }
        return destination
    }

    /// Starts a style from nothing. Empty of sections on purpose: a type with no section
    /// is left to the device, and every code the style does not cover is listed on the
    /// coverage screen.
    @discardableResult
    static func create(named name: String, familyID: Int = 6324, productID: Int = 1,
                       codePage: Int = CodePage.westernEuropean,
                       into library: URL = TypLibrary.directory) throws -> URL {
        let base = FileTools.slugify(name)
        guard !base.isEmpty else { throw ImportError.failed("a style needs a name") }
        Paths.ensure(library)

        let text = """
            ; -*- coding: UTF-8 -*-
            ; \(name)
            ;
            ; A style started from nothing. Every type kmap emits is listed on this style's
            ; coverage screen; the ones with no section here are drawn by the device, and
            ; adding a section is what takes one off that list.

            [_id]
            FID=\(familyID)
            ProductCode=\(productID)
            CodePage=\(codePage)
            [end]

            [_drawOrder]
            ; A polygon missing from this table is not drawn at all, whatever section it has.
            ; Adding a polygon through kmap puts it here too.
            [end]

            """
        let destination = freeName(base, extension: "txt", in: library)
        do {
            try text.write(to: destination, atomically: true, encoding: .utf8)
        } catch {
            throw ImportError.failed(error.localizedDescription)
        }
        return destination
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// A second copy of an entry, under a dated name, with its original copied along.
    @discardableResult
    static func duplicate(_ url: URL, library: URL = TypLibrary.directory,
                          on day: Date = Date()) throws -> URL {
        guard mayWrite(to: url, library: library) else {
            throw ImportError.failed("\(Paths.display(url)) is not in kmap's TYP library")
        }
        let base = url.deletingPathExtension().lastPathComponent
        let destination = datedName(base, extension: url.pathExtension, in: library, on: day)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            throw ImportError.failed(error.localizedDescription)
        }
        // The pair stays a pair: a copy with no original of its own could not be
        // restored, and would read as never imported.
        if let kept = original(of: url, library: library) {
            let beside = originalsDirectory(in: library).appendingPathComponent(
                destination.deletingPathExtension().lastPathComponent + ".typ")
            try? FileManager.default.copyItem(at: kept, to: beside)
        }
        if let kept = sheet(of: url, library: library) {
            let beside = sheetsDirectory(in: library).appendingPathComponent(
                destination.deletingPathExtension().lastPathComponent + ".txt")
            try? FileManager.default.copyItem(at: kept, to: beside)
        }
        return destination
    }

}
