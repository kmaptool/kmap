import Foundation

/// Finding what can be built with: the built-ins, the TYP library, and any hand-made
/// style directory. Discovery only reads; materialization is the catalog's other half.
extension StyleCatalog {
    /// Every style that can be built with. `scanning` is always false.
    func styles() -> (list: [MapStyle], scanning: Bool) {
        (availableStyles(), false)
    }

    /// Re-reads the library, so a TYP just imported is noticed.
    func rescanStyles() {}

    /// The styles available without a library: the plain rule set, and one per shipped
    /// palette.
    private func builtinStyles() -> [MapStyle] {
        var out: [MapStyle] = []
        out.append(
            MapStyle(
                id: "plain",
                name: "Plain",
                summary: "mkgmap's own rendering, no TYP — whatever your device defaults to",
                origin: .builtin,
                styleDirectory: StyleCatalog.baseStyleDirectory,
                typURL: nil,
                familyID: 6324,
                productID: 1
            )
        )
        for shipped in StyleCatalog.shippedPalettes {
            // The file is the binary's palette written out, and a build rewrites it;
            // refreshed on sight too, so a binary carrying new icons never shows a
            // stale look on the styles and type-list screens.
            let url = StyleCatalog.shippedTypURL(of: shipped)
            if let text = try? StyleCatalog.shippedTypText(of: shipped),
                (try? String(contentsOf: url, encoding: .utf8)) != text
            {
                Paths.ensure(url.deletingLastPathComponent())
                try? FileTools.write(text, to: url)
            }
            out.append(
                MapStyle(
                    id: shipped.id,
                    name: shipped.name,
                    summary: shipped.summary,
                    origin: .builtin,
                    styleDirectory: StyleCatalog.baseStyleDirectory,
                    typURL: url,
                    familyID: shipped.fid,
                    productID: 1
                )
            )
        }
        return out
    }

    /// Everything buildable. A TYP is offered only once imported into the library, never
    /// from where it lies on disk.
    func availableStyles() -> [MapStyle] {
        var out = builtinStyles()

        let imported = libraryStyles()

        out.append(contentsOf: imported)
        out.append(contentsOf: customDirectoryStyles())
        let owners = StyleIDOwners.load()
        let distinct = Self.distinctIDs(out, owners: owners)
        StyleIDOwners.remember(distinct, was: owners)
        return distinct
    }

    /// Ids made unique by a number. An id `owners` records goes back to its style where
    /// it is still there, numbered or not; a plain id left goes to the first in the list,
    /// the one a lookup by id meets first, and the rest are numbered. A numbered recovered
    /// style gets a numbered folder.
    static func distinctIDs(_ styles: [MapStyle], owners: [String: String] = [:]) -> [MapStyle] {
        // A style's own id is never given to another: `topo-2` may be a style's own name.
        let own = Set(styles.map(\.id))
        var assigned: [String?] = Array(repeating: nil, count: styles.count)
        var taken = Set<String>()
        func isNumbered(_ id: String, of base: String) -> Bool {
            guard id.hasPrefix(base + "-") else { return false }
            let tail = id.dropFirst(base.count + 1)
            return !tail.isEmpty && tail.allSatisfy(\.isNumber)
        }
        for (index, style) in styles.enumerated() {
            let key = StyleIDOwners.key(of: style)
            let recorded = owners.filter { id, owner in
                owner == key && !taken.contains(id)
                    && (id == style.id || (isNumbered(id, of: style.id) && !own.contains(id)))
            }.keys
            guard let id = recorded.contains(style.id) ? style.id : recorded.sorted().first else { continue }
            assigned[index] = id
            taken.insert(id)
        }
        for (index, style) in styles.enumerated() where assigned[index] == nil && !taken.contains(style.id) {
            assigned[index] = style.id
            taken.insert(style.id)
        }
        for (index, style) in styles.enumerated() where assigned[index] == nil {
            var count = 2
            while taken.contains("\(style.id)-\(count)") || own.contains("\(style.id)-\(count)") { count += 1 }
            assigned[index] = "\(style.id)-\(count)"
            taken.insert("\(style.id)-\(count)")
        }
        return styles.enumerated().map { index, style in
            let id = assigned[index] ?? style.id
            guard id != style.id else { return style }
            // Only kmap's own recovered rule set: a folder of the user's is where it is.
            let recovered: Bool
            if case .importedTYP = style.origin { recovered = true } else { recovered = false }
            let number = id.dropFirst(style.id.count)
            let folder = style.styleDirectory.map { folder in
                recovered && folder.lastPathComponent.hasPrefix("recovered-")
                    ? folder.deletingLastPathComponent()
                        .appendingPathComponent(folder.lastPathComponent + number, isDirectory: true)
                    : folder
            }
            return MapStyle(
                id: id,
                name: style.name,
                summary: style.summary,
                origin: style.origin,
                styleDirectory: folder,
                typURL: style.typURL,
                familyID: style.familyID,
                productID: style.productID
            )
        }
    }

    func style(id: String) -> MapStyle? {
        Self.find(id, in: availableStyles())
    }

    /// Whether a saved id names `style`, 1.7.3's spelling included.
    static func names(_ id: String, _ style: MapStyle) -> Bool {
        find(id, in: [style]) != nil
    }

    /// The style a saved id names. A recovered rule set saved as a folder's style,
    /// `dir:recovered-x`, is the library style the folder is made for.
    static func find(_ id: String, in styles: [MapStyle]) -> MapStyle? {
        if let found = styles.first(where: { $0.id == id }) { return found }
        guard id.hasPrefix("dir:recovered-") else { return nil }
        return styles.first { style in
            guard case .importedTYP = style.origin, let folder = style.styleDirectory else { return false }
            return "dir:" + FileTools.slugify(folder.lastPathComponent) == id
        }
    }

    /// The TYP library as buildable styles: one entry per file in `~/.kmap/typ`.
    private func libraryStyles() -> [MapStyle] {
        TypLibrary.contents()
            .compactMap(StyleCatalog.libraryStyle(at:))
            .sorted { $0.name < $1.name }
    }

    /// One library file as a style. A file with a recovered sheet gets a rule set of its
    /// own: the base rules with the sheet's reassignments applied.
    ///
    /// - Returns: nil if the TYP header will not read.
    static func libraryStyle(at url: URL) -> MapStyle? {
        guard let info = TypInfo.read(url) else { return nil }
        let base = url.deletingPathExtension().lastPathComponent
        let sheet = TypLibrary.sheet(of: url)
        return MapStyle(
            id: "typ:" + FileTools.slugify(base),
            name: base,
            // In the interface's language as it is read: the screens show it as it stands.
            summary: (info.isBinary ? t("compiled TYP") : t("editable TYP source"))
                + " · " + t("family %d", info.familyID) + " · \(Fmt.bytes(FileTools.size(of: url)))"
                + (sheet != nil ? " · " + t("rules recovered from its map") : ""),
            origin: .importedTYP(url),
            styleDirectory: sheet != nil
                ? StyleCatalog.recoveredStyleDirectory(for: url)
                : StyleCatalog.baseStyleDirectory,
            typURL: url,
            familyID: info.familyID,
            productID: info.productID
        )
    }

    /// Where the rule set for a style with a recovered sheet is materialized.
    static func recoveredStyleDirectory(for typ: URL) -> URL {
        Paths.styles.appendingPathComponent(
            "recovered-" + FileTools.slugify(typ.deletingPathExtension().lastPathComponent),
            isDirectory: true
        )
    }

    /// kmap's own folders among the styles: the base, recovered rule sets (by their
    /// marker), and anything hidden, which kmap's staging and swaps are. Windows hides by
    /// an attribute, not by a dot.
    static func isKmapsOwnFolder(_ dir: URL) -> Bool {
        let name = dir.lastPathComponent
        return name == "kmap-base" || name.hasPrefix(".") || isUnpacking(name)
            || (name.hasPrefix("recovered-") && FileTools.exists(dir.appendingPathComponent("kmap-version")))
    }

    /// An unpacking of kmap's: hidden, or `unpack-` and 8 hex digits. A folder of the
    /// user's called `unpack-maps` is not one.
    static func isUnpacking(_ name: String) -> Bool {
        if name.hasPrefix(".unpack-") { return true }
        guard name.hasPrefix("unpack-") else { return false }
        let tail = name.dropFirst("unpack-".count)
        return tail.count == 8 && tail.allSatisfy(\.isHexDigit)
    }

    /// A rule set of kmap's set aside by a swap cut short; see `swappedOut(_:)`.
    static func isSwappedOut(_ name: String) -> Bool {
        name == ".kmap-base.old" || (name.hasPrefix(".recovered-") && name.hasSuffix(".old"))
    }

    /// A folder under ~/.kmap/styles containing a `lines` file is a hand-made mkgmap style.
    private func customDirectoryStyles() -> [MapStyle] {
        let items =
            (try? FileManager.default.contentsOfDirectory(
                at: Paths.styles,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

        return items.compactMap { dir -> MapStyle? in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue,
                !Self.isKmapsOwnFolder(dir),
                FileTools.exists(dir.appendingPathComponent("lines"))
            else { return nil }

            let typ =
                FileTools.contents(of: dir, extension: "typ").first
                ?? FileTools.contents(of: dir, extension: "txt").first { TypInfo.read($0) != nil }
            let info = typ.flatMap { TypInfo.read($0) }

            return MapStyle(
                id: "dir:" + FileTools.slugify(dir.lastPathComponent),
                name: dir.lastPathComponent,
                summary: "custom style in \(Paths.display(Paths.styles))",
                origin: .customDirectory(dir),
                styleDirectory: dir,
                typURL: typ,
                familyID: info?.familyID ?? 6324,
                productID: info?.productID ?? 1
            )
        }.sorted { $0.name < $1.name }
    }
}
