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
        out.append(MapStyle(
            id: "plain",
            name: "Plain",
            summary: "mkgmap's own rendering, no TYP — whatever your device defaults to",
            origin: .builtin,
            styleDirectory: StyleCatalog.baseStyleDirectory,
            typURL: nil,
            familyID: 6324,
            productID: 1))
        for shipped in StyleCatalog.shippedPalettes {
            // The file is the binary's palette written out, and a build rewrites it;
            // refreshed on sight too, so a binary carrying new icons never shows a
            // stale look on the styles and type-list screens.
            let url = StyleCatalog.shippedTypURL(of: shipped)
            if let text = try? StyleCatalog.shippedTypText(of: shipped),
               (try? String(contentsOf: url, encoding: .utf8)) != text {
                Paths.ensure(url.deletingLastPathComponent())
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
            out.append(MapStyle(
                id: shipped.id,
                name: shipped.name,
                summary: shipped.summary,
                origin: .builtin,
                styleDirectory: StyleCatalog.baseStyleDirectory,
                typURL: url,
                familyID: shipped.fid,
                productID: 1))
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
        return out
    }

    func style(id: String) -> MapStyle? {
        availableStyles().first { $0.id == id }
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
            summary: (info.isBinary ? "compiled TYP" : "editable TYP source")
                + " · family \(info.familyID) · \(Fmt.bytes(FileTools.size(of: url)))"
                + (sheet != nil ? " · rules recovered from its map" : ""),
            origin: .importedTYP(url),
            styleDirectory: sheet != nil
                ? StyleCatalog.recoveredStyleDirectory(for: url)
                : StyleCatalog.baseStyleDirectory,
            typURL: url,
            familyID: info.familyID,
            productID: info.productID)
    }

    /// Where the rule set for a style with a recovered sheet is materialized.
    static func recoveredStyleDirectory(for typ: URL) -> URL {
        Paths.styles.appendingPathComponent(
            "recovered-" + FileTools.slugify(typ.deletingPathExtension().lastPathComponent),
            isDirectory: true)
    }

    /// A folder under ~/.kmap/styles containing a `lines` file is a hand-made mkgmap style.
    private func customDirectoryStyles() -> [MapStyle] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: Paths.styles, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []

        return items.compactMap { dir -> MapStyle? in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue,
                  dir.lastPathComponent != "kmap-base",
                  FileTools.exists(dir.appendingPathComponent("lines")) else { return nil }

            let typ = FileTools.contents(of: dir, extension: "typ").first
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
                productID: info?.productID ?? 1)
        }.sorted { $0.name < $1.name }
    }
}
