import Foundation

/// Getting a TYP into the library: finding candidates on the mounted volumes,
/// taking a copy in, the import log, and the kept originals a style can be
/// restored from.
struct TypCandidate: Equatable, Identifiable, Sendable {
    /// The file it would come from.
    let url: URL
    /// True when the TYP is inside a Garmin `.img` and has to be lifted out.
    let isEmbedded: Bool

    let familyID: Int
    let productID: Int
    let size: Int64


    /// What to call it on screen: the file's own name, or the map's for an embedded one.
    let name: String
    /// The folder it was found in, for telling two copies of the same product apart.
    let location: String

    /// The TYP's own bytes, boiled down to a number. Zero where it could not be read.
    ///
    /// A family id names the product, not the file: one product may ship several TYPs
    /// under one family, and several versions of a map may ship different ones.
    var fingerprint: UInt64 = 0

    var id: String { "\(url.path)#\(familyID)" }
}

/// The folder of TYPs kmap may edit. Nothing outside it is written to: a TYP on a mounted
/// drive or inside a `.img` belongs to the product that shipped it, so borrowing a look
/// means taking a copy first, and the copy is what the editor is pointed at. An import
/// never overwrites a file already here, which may have been edited since.

extension TypLibrary {
    // MARK: Finding things to import

    /// Where to look for TYPs worth borrowing: the Garmin folder of the home directory
    /// and of every mounted volume, which directories count as mounted being answered
    /// per platform. The library is the destination, not a source, and is excluded.
    static func searchRoots(volumes: [URL] = Platform.mountedVolumes()) -> [URL] {
        var roots = [Paths.home.appendingPathComponent("Garmin", isDirectory: true)]
        for volume in volumes {
            roots.append(volume.appendingPathComponent("Garmin", isDirectory: true))
        }
        return roots.filter { FileTools.exists($0) }
    }

    /// Walks the search roots for anything holding a TYP. Blocking and slow — it reaches
    /// into every Garmin folder on every volume — so call it off the render loop.
    /// - Parameter excluding: kmap's own output folder, which is skipped.
    static func discover(excluding output: URL?) -> [TypCandidate] {
        var found: [TypCandidate] = []
        var seenProducts = Set<String>()
        let outputPath = output.map { $0.standardizedFileURL.path + "/" }

        for root in searchRoots() {
            for url in files(under: root, excludingPrefix: outputPath) {
                let extensionName = url.pathExtension.lowercased()
                let folder = url.deletingLastPathComponent().lastPathComponent

                if extensionName == "typ" {
                    guard let info = TypInfo.read(url) else { continue }
                    found.append(TypCandidate(
                        url: url, isEmbedded: false,
                        familyID: info.familyID, productID: info.productID,
                        size: FileTools.size(of: url),
                        name: url.deletingPathExtension().lastPathComponent,
                        location: folder,
                        fingerprint: fingerprint(ofTypAt: url)))
                } else if extensionName == "img" {
                    guard let identity = ImgContainer.typIdentity(in: url) else { continue }
                    // One entry per product: a split map carries the same TYP in both
                    // halves, and a product folder holds hundreds of tiles that all do.
                    let key = "\(identity.familyID)-\(identity.productID)-\(identity.size)"
                    guard seenProducts.insert(key).inserted else { continue }
                    // Fingerprinted only after the cheap key has dropped the duplicates:
                    // reading tens of kilobytes from every tile of a folder is slow.
                    found.append(TypCandidate(
                        url: url, isEmbedded: true,
                        familyID: identity.familyID, productID: identity.productID,
                        size: Int64(identity.size),
                        name: folder,
                        location: url.lastPathComponent,
                        fingerprint: fingerprint(ofTypAt: url)))
                }
            }
        }
        return found.sorted {
            ($0.name.lowercased(), $0.familyID) < ($1.name.lowercased(), $1.familyID)
        }
    }

    private static func files(under root: URL, excludingPrefix output: String?) -> [URL] {
        var out: [URL] = []
        let rootDepth = root.pathComponents.count
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return out }

        for case let url as URL in walker {
            if url.pathComponents.count - rootDepth > 3 {
                walker.skipDescendants()
                continue
            }
            // A .gmap bundle holds hundreds of per-tile files and one TYP that also
            // exists as a plain .typ beside it.
            if url.pathExtension.lowercased() == "gmap" {
                walker.skipDescendants()
                continue
            }
            if let output, url.standardizedFileURL.path.hasPrefix(output) {
                walker.skipDescendants()
                continue
            }
            // kmap's own output, wherever it was put: every build leaves a
            // build-info.txt beside its .img, which the configured folder alone misses.
            if isDirectory(url), FileTools.exists(url.appendingPathComponent("build-info.txt")) {
                walker.skipDescendants()
                continue
            }
            if ["typ", "img"].contains(url.pathExtension.lowercased()) { out.append(url) }
            if out.count > 400 { break }
        }
        return out
    }

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

    /// What an import produced.
    struct Imported {
        /// The library entry — the file the editor will be pointed at.
        let url: URL
        /// True when the TYP was compiled and has been written back out as source.
        let decompiled: Bool
        /// How many elements were read, and how many of those the decoder refused.
        let elements: Int
        let refused: Int
        /// Where the untouched original was kept, for a compiled import.
        let original: URL?
        /// The TYP's own bytes, boiled down to a number, written into the import log.
        let fingerprint: UInt64
    }

    /// Takes a copy of a candidate into the library.
    @discardableResult
    static func take(_ candidate: TypCandidate,
                     into directory: URL = TypLibrary.directory,
                     on day: Date = Date()) throws -> Imported {
        try take(at: candidate.url, into: directory, on: day)
    }

    // MARK: Working with what is already held

    /// The untouched binary kept beside an entry, where there is one. Only a compiled
    /// import has one: a style created from nothing, or arriving as source, is its own
    /// original.
    static func original(of url: URL, library: URL = TypLibrary.directory) -> URL? {
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
                t("this style has no original kept — nothing was imported to go back to"))
        }
        guard let decoded = try? TypBinary.read(kept) else {
            throw ImportError.failed(t("%@ could not be decoded", kept.lastPathComponent))
        }
        let text = TypDecompiler.source(decoded, origin: kept.lastPathComponent)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw ImportError.failed(error.localizedDescription)
        }
        return url
    }

    /// The log of what was taken in, from where, and when. A `.log` beside the styles
    /// rather than inside them: `contents` lists only `.typ` and `.txt`, so it is not
    /// itself a style.
    static func importLog(in directory: URL = TypLibrary.directory) -> URL {
        directory.appendingPathComponent("imported.log")
    }

    /// Appends one line to that log. Failure is ignored: a note about an import is not
    /// worth failing the import over.
    static func recordImport(from source: URL, to destination: URL, at when: Date = Date(),
                             fingerprint mark: UInt64 = 0,
                             note: String, in directory: URL = TypLibrary.directory) {
        let stamp = ISO8601DateFormatter().string(from: when)
        // The fingerprint answers what the path cannot once the drive it names is gone:
        // whether the file kept in originals/ is still the one taken that day.
        let identity = mark == 0 ? "-" : String(format: "%016llx", mark)
        let line = "\(stamp)\t\(destination.lastPathComponent)\t\(identity)"
            + "\t\(source.path)\t\(note)\n"
        let url = importLog(in: directory)
        Paths.ensure(directory)
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// The map a library entry was taken out of, from the latest import-log line naming
    /// it, and only while that path is still a Garmin container.
    ///
    /// The log exists in two shapes — with and without the fingerprint column — so the
    /// path is found by ruling the fingerprint out rather than by counting columns. It
    /// used to be found by asking which field began with a slash, which is a question
    /// only a Unix path answers yes to: on Windows the path begins `C:\`, no field
    /// matched, and kmap could never say which map a style had come from.
    static func importedSource(of entry: URL,
                               library: URL = TypLibrary.directory) -> URL? {
        guard let text = try? String(contentsOf: importLog(in: library), encoding: .utf8)
        else { return nil }
        let name = entry.lastPathComponent
        for line in Lines.of(text).reversed() {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                .map(String.init)
            guard fields.count >= 3, fields[1] == name else { continue }
            let path = isFingerprint(fields[2]) ? fields.dropFirst(3).first : fields[2]
            guard let path, !path.isEmpty else { continue }
            let source = URL(fileURLWithPath: path)
            return FileTools.exists(source) && ImgContainer.isImg(source) ? source : nil
        }
        return nil
    }

    /// Whether a field is the fingerprint column: sixteen hex digits, or the dash written
    /// where there was nothing to fingerprint. Nothing else is that shape, and a path
    /// never is — it has a separator in it.
    private static func isFingerprint(_ field: String) -> Bool {
        if field == "-" { return true }
        return field.count == 16 && field.allSatisfy(\.isHexDigit)
    }

    /// Where an imported binary is kept, untouched, beside its decompiled source: a
    /// subfolder, so it does not appear in the library listing. Kept because the source
    /// is a reconstruction, and the original still builds where the decoder refused.
    static func originalsDirectory(in directory: URL = TypLibrary.directory) -> URL {
        directory.appendingPathComponent("originals", isDirectory: true)
    }

    /// Takes a copy of whatever is at `url`: a TYP is copied, a `.img` has its TYP lifted
    /// out. Returns where it landed. Never overwrites — a file already in the library may
    /// have been edited — so the copy gets a dated or numbered name instead.
    @discardableResult
    static func take(at url: URL, into directory: URL = TypLibrary.directory,
                     on day: Date = Date()) throws -> Imported {
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
                : url.deletingPathExtension().lastPathComponent)
        let base = stem.contains("\(info.familyID)") ? stem : "\(stem)-\(info.familyID)"

        // Source comes in as source: nothing to decompile, and nothing to keep a copy of.
        guard info.isBinary else {
            let destination = datedName(base, extension: "txt", in: directory, on: day)
            do {
                try FileManager.default.copyItem(at: binary, to: destination)
            } catch {
                throw ImportError.failed(error.localizedDescription)
            }
            return Imported(url: destination, decompiled: false, elements: 0,
                            refused: 0, original: nil, fingerprint: mark)
        }

        // Compiled: decompile it, so the library entry is editable. The original is kept
        // beside it, the decompiled source being a reconstruction.
        guard let decoded = try? TypBinary.read(binary) else {
            let destination = datedName(base, extension: "typ", in: directory, on: day)
            try? FileManager.default.copyItem(at: binary, to: destination)
            throw ImportError.failed(
                "\(url.lastPathComponent) could not be decoded — the copy at "
                + "\(Paths.display(destination)) can still be built with, but not edited")
        }

        let destination = datedName(base, extension: "txt", in: directory, on: day)
        let text = TypDecompiler.source(decoded, origin: url.lastPathComponent)
        do {
            try text.write(to: destination, atomically: true, encoding: .utf8)
        } catch {
            throw ImportError.failed(error.localizedDescription)
        }

        let originals = originalsDirectory(in: directory)
        Paths.ensure(originals)
        let kept = originals.appendingPathComponent(destination
            .deletingPathExtension().lastPathComponent + ".typ")
        FileTools.removeIfPresent(kept)
        try? FileManager.default.copyItem(at: binary, to: kept)

        return Imported(url: destination, decompiled: true,
                        elements: decoded.all.count,
                        refused: decoded.all.count - decoded.exactCount,
                        original: FileTools.exists(kept) ? kept : nil,
                        fingerprint: mark)
    }

    /// A free name for an import, dated rather than numbered where the plain one is taken:
    /// a second import of the same product is usually a newer version of it. Two imports
    /// on one day fall back to a number after the date.
    static func datedName(_ base: String, extension suffix: String, in directory: URL,
                          on day: Date = Date()) -> URL {
        let plain = directory.appendingPathComponent("\(base).\(suffix)")
        guard FileTools.exists(plain) else { return plain }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd"
        // Fixed locale, local calendar: the name is the same string whatever the machine's
        // language, and the date is the local one.
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = TimeZone.current
        return freeName("\(base)-\(stamp.string(from: day))", extension: suffix,
                        in: directory)
    }

    static func freeName(_ base: String, extension suffix: String,
                                 in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent("\(base).\(suffix)")
        var counter = 2
        while FileTools.exists(candidate) {
            candidate = directory.appendingPathComponent("\(base)-\(counter).\(suffix)")
            counter += 1
        }
        return candidate
    }
}
