import Foundation

/// The folder of TYPs kmap may edit. Nothing outside it is written to: a TYP on a mounted
/// drive or inside a `.img` belongs to the product that shipped it, so borrowing a look
/// means taking a copy first, and the copy is what the editor is pointed at. An import
/// never overwrites a file already here, which may have been edited since.

extension TypLibrary {
    // MARK: Taking a copy

    enum ImportError: LocalizedError {
        case notFound(String)
        case notATyp(String)
        case noTypInside(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notFound(let path): return t("%@: no such file", path)
            case .notATyp(let name): return t("%@ is neither a TYP nor a Garmin .img", name)
            case .noTypInside(let name): return t("%@ holds no TYP", name)
            case .failed(let why): return why
            }
        }
    }

    /// Takes a copy of a candidate into the library.
    @discardableResult
    static func take(
        _ candidate: TypCandidate,
        into directory: URL = TypLibrary.directory,
        on day: Date = Date()
    ) throws -> Imported {
        try take(at: candidate.url, into: directory, on: day)
    }

    // MARK: Working with what is already held

    /// The untouched binary kept beside an entry, where there is one. Only a compiled
    /// import has one: a style created from nothing, or arriving as source, is its own
    /// original.
    static func original(of url: URL, library: URL = TypLibrary.directory) -> URL? {
        // A compiled entry is its own original: the one kept by its name is a text entry's.
        guard url.pathExtension.lowercased() == "txt" else { return nil }
        let kept = originalsDirectory(in: library)
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".typ")
        return FileTools.exists(kept) ? kept : nil
    }

    /// Rewrites an entry from the binary kept when it was imported, discarding whatever
    /// edits the entry holds.
    @discardableResult
    static func restore(_ url: URL, library: URL = TypLibrary.directory) throws -> URL {
        guard mayWrite(to: url, library: library) else {
            throw ImportError.failed("\(Paths.display(url)) is not in kmap's TYP library")
        }
        guard let kept = original(of: url, library: library) else {
            throw ImportError.failed(
                t("this style has no original kept — nothing was imported to go back to")
            )
        }
        guard let decoded = try? TypBinary.read(kept) else {
            throw ImportError.failed(t("%@ could not be decoded", kept.lastPathComponent))
        }
        let text = TypDecompiler.source(decoded, origin: kept.lastPathComponent)
        do {
            try FileTools.write(TypSource.bytesOfWritten(text, codePage: decoded.codePage), to: url)
        } catch {
            throw ImportError.failed(error.localizedDescription)
        }
        return url
    }

    /// Where an imported binary is kept, untouched, beside its decompiled source: a
    /// subfolder, so it does not appear in the library listing. Kept because the source
    /// is a reconstruction, and the original still builds where the decoder refused.
    static func originalsDirectory(in directory: URL = TypLibrary.directory) -> URL {
        directory.appendingPathComponent("originals", isDirectory: true)
    }

    /// Takes a copy of whatever is at `url`: a TYP is copied, a `.img` has its TYP lifted
    /// out. Returns where it landed. Never overwrites - a file already in the library may
    /// have been edited - so the copy gets a dated or numbered name instead.
    @discardableResult
    static func take(
        at url: URL,
        into directory: URL = TypLibrary.directory,
        on day: Date = Date()
    ) throws -> Imported {
        guard FileTools.exists(url) else { throw ImportError.notFound(Paths.display(url)) }
        Paths.ensure(directory)

        // A .img is a container; what is wanted is the TYP inside it.
        var binary = url
        var temporary: URL?
        if ImgContainer.isImg(url) {
            guard let identity = ImgContainer.typIdentity(in: url) else {
                throw ImportError.noTypInside(url.lastPathComponent)
            }
            _ = identity
            let scratch = directory.appendingPathComponent(".lifting-\(UUID().uuidString).typ")
            guard ImgContainer.extractTYP(from: url, to: scratch) else {
                throw ImportError.failed("could not lift the TYP out of \(url.lastPathComponent)")
            }
            binary = scratch
            temporary = scratch
        }
        defer { if let temporary { FileTools.removeIfPresent(temporary) } }

        guard let info = TypInfo.read(binary) else {
            throw ImportError.notATyp(url.lastPathComponent)
        }
        // Taken here, where the bytes are already in hand and before anything is written.
        let mark = fingerprint(ofTypAt: binary)

        let stem = FileTools.slugify(
            ImgContainer.isImg(url)
                ? "\(url.deletingLastPathComponent().lastPathComponent)-"
                    + url.deletingPathExtension().lastPathComponent
                : url.deletingPathExtension().lastPathComponent
        )
        let base = stem.contains("\(info.familyID)") ? stem : "\(stem)-\(info.familyID)"

        // Source comes in as source: nothing to decompile, and nothing to keep a copy of.
        guard info.isBinary else {
            let destination = datedName(base, extension: "txt", in: directory, on: day)
            do {
                // Byte for byte where every byte reads alike in any code page, or the page
                // is one kmap cannot read; otherwise as UTF-8 and saying so.
                let bytes = try Data(contentsOf: binary)
                if bytes.allSatisfy({ $0 < 0x80 }) {
                    try FileTools.copy(binary, to: destination)
                } else {
                    let read = TypSource.decoding([UInt8](bytes))
                    try FileTools.write(
                        TypSource.bytesToWrite(read.text, declaring: true, byteForByte: read.byteForByte),
                        to: destination
                    )
                }
            } catch {
                throw ImportError.failed(error.localizedDescription)
            }
            return Imported(
                url: destination,
                decompiled: false,
                elements: 0,
                refused: 0,
                original: nil,
                fingerprint: mark
            )
        }

        // Compiled: decompile it, so the library entry is editable. The original is kept
        // beside it, the decompiled source being a reconstruction.
        guard let decoded = try? TypBinary.read(binary) else {
            let destination = datedName(base, extension: "typ", in: directory, on: day)
            try? FileTools.copy(binary, to: destination)
            throw ImportError.failed(
                "\(url.lastPathComponent) could not be decoded — the copy at "
                    + "\(Paths.display(destination)) can still be built with, but not edited"
            )
        }

        let destination = datedName(base, extension: "txt", in: directory, on: day)
        let text = TypDecompiler.source(decoded, origin: url.lastPathComponent)
        do {
            try FileTools.write(TypSource.bytesOfWritten(text, codePage: decoded.codePage), to: destination)
        } catch {
            throw ImportError.failed(error.localizedDescription)
        }

        let originals = originalsDirectory(in: directory)
        Paths.ensure(originals)
        let kept = originals.appendingPathComponent(
            destination
                .deletingPathExtension().lastPathComponent + ".typ"
        )
        FileTools.removeIfPresent(kept)
        try? FileTools.copy(binary, to: kept)

        return Imported(
            url: destination,
            decompiled: true,
            elements: decoded.all.count,
            refused: decoded.all.count - decoded.exactCount,
            original: FileTools.exists(kept) ? kept : nil,
            fingerprint: mark
        )
    }

    /// A free name for an import, dated rather than numbered where the plain one is taken:
    /// a second import of the same product is usually a newer version of it. 2 imports
    /// on one day fall back to a number after the date.
    static func datedName(
        _ base: String,
        extension suffix: String,
        in directory: URL,
        on day: Date = Date()
    ) -> URL {
        let plain = directory.appendingPathComponent("\(base).\(suffix)")
        guard taken(base, extension: suffix, in: directory) else { return plain }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd"
        // Fixed locale, local calendar: the name is the same string whatever the machine's
        // language, and the date is the local one.
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = TimeZone.current
        return freeName(
            "\(base)-\(stamp.string(from: day))",
            extension: suffix,
            in: directory
        )
    }

    static func freeName(
        _ base: String,
        extension suffix: String,
        in directory: URL
    ) -> URL {
        var stem = base
        var counter = 2
        while taken(stem, extension: suffix, in: directory) {
            stem = "\(base)-\(counter)"
            counter += 1
        }
        return directory.appendingPathComponent("\(stem).\(suffix)")
    }

    /// Whether a library name is in use. A style's id and its kept original go by the name
    /// without its extension, so `.typ` and `.txt` of 1 name would be 1 style. `Foo Bar.typ`
    /// holds `foo-bar` too, its id.
    private static func taken(_ stem: String, extension suffix: String, in directory: URL) -> Bool {
        let kinds = ["typ", "txt"].contains(suffix.lowercased()) ? ["typ", "txt"] : [suffix]
        if kinds.contains(where: { FileTools.exists(directory.appendingPathComponent("\(stem).\($0)")) }) {
            return true
        }
        let id = FileTools.slugify(stem)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let ids = names.compactMap { name -> String? in
            let file = URL(fileURLWithPath: name)
            guard kinds.contains(file.pathExtension.lowercased()) else { return nil }
            return FileTools.slugify(file.deletingPathExtension().lastPathComponent)
        }
        // And the numbers 2 files of 1 id are told apart by, which a profile may have saved.
        let numbered = Dictionary(grouping: ids, by: { $0 }).flatMap { slug, files in
            files.count > 1 ? (2...files.count).map { "\(slug)-\($0)" } : []
        }
        return ids.contains(id) || numbered.contains(id)
    }
}
