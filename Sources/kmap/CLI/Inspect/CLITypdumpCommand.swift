import Foundation

/// `kmap typdump`: a compiled TYP decoded. Colours, widths, pictures, labels and the draw
/// order, from a `.typ` or from a `.img` with the TYP lifted out first.
extension CLI {
    static func typdump(_ arguments: [String]) -> Int32 {
        let flags = Flags(arguments, valued: ["type"])
        guard let path = flags.positionals.first else {
            return CLIOutput.refuse(
                "usage: kmap typdump <file.typ|map.img> [--polygons] [--lines] [--points]"
                    + " [--draw-order] [--all] [--type=0xNN]\n"
            )
        }
        let url = Paths.expand(path)
        guard FileTools.exists(url) else {
            return CLIOutput.refuse("\(url.lastPathComponent): not found")
        }

        // A map rather than a TYP: lifted into a place that goes away again.
        var typURL = url
        var lifted: URL?
        defer { if let lifted { FileTools.removeIfPresent(lifted.deletingLastPathComponent()) } }
        if ImgContainer.isImg(url) {
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("kmap-typdump-\(UUID().uuidString.prefix(8))")
            Paths.ensure(staging)
            // A file path, not the directory: extractTYP writes to the exact URL given.
            let landed = staging.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".typ")
            guard ImgContainer.extractTYP(from: url, to: landed) else {
                return CLIOutput.failure("\(url.lastPathComponent): " + t("no TYP inside"))
            }
            typURL = landed
            lifted = landed
        }

        let typ: TypBinary
        do {
            typ = try TypBinary.read(typURL)
        } catch {
            return CLIOutput.failure("\(error.localizedDescription)")
        }

        let wantedTypes: Set<Int> = Set(
            flags.values("type").compactMap { text -> Int? in
                Int(text.hasPrefix("0x") ? text.dropFirst(2) : text[...], radix: 16)
            }
        )
        let all = flags.has("all")
        var kinds: [MapElementKind] = []
        if all || flags.has("polygons") { kinds.append(.polygon) }
        if all || flags.has("lines") { kinds.append(.line) }
        if all || flags.has("points") { kinds.append(.point) }
        if kinds.isEmpty && !wantedTypes.isEmpty { kinds = [.polygon, .line, .point] }

        CLILog.line("\(typURL.lastPathComponent)")
        CLILog.line("  " + t("code page %d · family %d · product %d", typ.codePage, typ.familyID, typ.productID))
        CLILog.line(
            "  "
                + t(
                    "%d polygon(s), %d line(s), %d point(s); %d of %d read exactly",
                    typ.polygons.count,
                    typ.lines.count,
                    typ.points.count,
                    typ.exactCount,
                    typ.all.count
                )
        )

        var dumped: [String: JSONValue] = [:]
        for kind in kinds {
            let elements = typ.elements(kind).filter { wantedTypes.isEmpty || wantedTypes.contains($0.code) }
            dumped[kind.ruleFile] = .array(elements.map(elementAsData))
            guard !elements.isEmpty else { continue }
            CLILog.line("\n@@ \(kind.ruleFile)")
            for element in elements { CLILog.line("  " + describe(element)) }
        }
        if all || flags.has("draw-order") {
            CLILog.line("\n@@ " + t("draw order"))
            for entry in typ.drawOrder {
                CLILog.line(String(format: "  0x%05x  level %d", entry.code, entry.level))
            }
        }
        CLIOutput.result([
            "file": .string(typURL.lastPathComponent),
            "codePage": .int(typ.codePage),
            "familyID": .int(typ.familyID),
            "productID": .int(typ.productID),
            "counts": [
                "polygons": .int(typ.polygons.count), "lines": .int(typ.lines.count),
                "points": .int(typ.points.count), "exact": .int(typ.exactCount),
                "all": .int(typ.all.count)
            ],
            "elements": .object(dumped),
            "drawOrder": .array(typ.drawOrder.map { ["code": .int($0.code), "level": .int($0.level)] })
        ])
        return 0
    }

    /// One element on one line: code, colours, widths, picture, and the label the TYP
    /// carries in whatever language it stores first.
    private static func describe(_ element: TypBinary.Element) -> String {
        var parts: [String] = [String(format: "0x%05x", element.code)]
        let colours = element.colours.map { $0 ?? "—" }
        if !colours.isEmpty { parts.append(colours.joined(separator: " ")) }
        if let width = element.lineWidth { parts.append("w\(width)") }
        if let border = element.borderWidth, border > 0 { parts.append("b\(border)") }
        if element.bitmap != nil { parts.append("\(element.bitmapHeight)px") }
        if element.dayImage != nil { parts.append("icon") }
        if !element.exact { parts.append("~") }
        let label = element.labels.first.map { " \($0.text)" } ?? ""
        return parts.joined(separator: "  ") + label
    }

    private static func elementAsData(_ element: TypBinary.Element) -> JSONValue {
        [
            "code": .int(element.code),
            "hex": .string(String(format: "0x%05x", element.code)),
            "colours": .array(element.colours.map { $0.map(JSONValue.string) ?? .null }),
            "lineWidth": .of(element.lineWidth),
            "borderWidth": .of(element.borderWidth),
            "bitmapHeight": element.bitmap == nil ? .null : .int(element.bitmapHeight),
            "hasIcon": .bool(element.dayImage != nil),
            "exact": .bool(element.exact),
            "labels": .array(element.labels.map { ["language": .int($0.language), "text": .string($0.text)] })
        ]
    }
}
