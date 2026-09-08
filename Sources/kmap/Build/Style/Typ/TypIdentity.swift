import Foundation

/// Telling one TYP from another — the fingerprint, what the library holds — and
/// the recovered rule sheet kept beside a library file.
extension TypLibrary {
    // MARK: Telling one TYP from another

    /// FNV-1a over the bytes. Identity, not security, hence no CryptoKit, which Linux
    /// has not got.
    static func fingerprint(_ bytes: Data) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01B3
        }
        return hash
    }

    /// The TYP's own bytes, lifted out of a container where it is in one. In memory: tens
    /// of kilobytes, wanted for comparison rather than for keeping.
    private static func typBytes(at url: URL) -> Data? {
        if ImgContainer.isImg(url) {
            guard let sub = ImgContainer.typSubFile(in: url) else { return nil }
            return ImgContainer.read(sub, from: url)
        }
        return try? Data(contentsOf: url)
    }

    static func fingerprint(ofTypAt url: URL) -> UInt64 {
        typBytes(at: url).map(fingerprint) ?? 0
    }

    /// What the library already holds, by the bytes and by the product.
    ///
    /// The bytes come from `originals/`, which keeps every imported binary untouched beside
    /// its decompiled source. A plain-copied entry has no binary of its own and counts
    /// towards the family but never towards an exact match.
    struct Held {
        /// Fingerprint to the library entry it belongs to.
        var exact: [UInt64: String] = [:]
        /// "family-product" of everything held, however it arrived.
        var families: Set<String> = []
    }

    static func held(in directory: URL = TypLibrary.directory) -> Held {
        var out = Held()
        // Only an original whose entry is still there: a folder tidied by hand can leave
        // an orphan, which would report a missing style as already in the library.
        let entries = Set(contents(in: directory)
            .map { $0.deletingPathExtension().lastPathComponent })
        for url in contents(in: originalsDirectory(in: directory)) {
            let name = url.deletingPathExtension().lastPathComponent
            guard entries.contains(name) else { continue }
            let mark = fingerprint(ofTypAt: url)
            if mark != 0 { out.exact[mark] = name }
        }
        for url in contents(in: directory) {
            guard let info = TypInfo.read(url) else { continue }
            out.families.insert("\(info.familyID)-\(info.productID)")
            // A binary in the library itself, imported as it was rather than decompiled:
            // its own bytes are what to compare against.
            guard url.pathExtension.lowercased() == "typ" else { continue }
            let mark = fingerprint(ofTypAt: url)
            if mark != 0 { out.exact[mark] = url.deletingPathExtension().lastPathComponent }
        }
        return out
    }

    /// How much of this candidate the library already has.
    enum Holding: Equatable {
        /// Nothing like it.
        case none
        /// Something of the same product, but not these bytes: another variant, or another
        /// version of the same map.
        case family
        /// This exact file, and what it is called in the library.
        case exact(String)
    }

    static func holding(of candidate: TypCandidate, in held: Held) -> Holding {
        if candidate.fingerprint != 0, let name = held.exact[candidate.fingerprint] {
            return .exact(name)
        }
        return held.families.contains("\(candidate.familyID)-\(candidate.productID)")
            ? .family : .none
    }

    // MARK: Recovered rule sheets

    /// Where a style's recovered reassignment sheet lives: a folder of its own, so the
    /// sheets never show up in the library listing as styles.
    static func sheetsDirectory(in library: URL = TypLibrary.directory) -> URL {
        library.appendingPathComponent("recovered", isDirectory: true)
    }

    /// A reassignment sheet left beside a style by an older kmap, which wrote one
    /// where this version rewrites the style itself. Read, never written.
    static func sheet(of url: URL, library: URL = TypLibrary.directory) -> URL? {
        let kept = sheetsDirectory(in: library)
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".txt")
        return FileTools.exists(kept) ? kept : nil
    }
}
