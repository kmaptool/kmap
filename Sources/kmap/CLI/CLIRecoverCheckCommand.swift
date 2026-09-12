import Foundation

/// `kmap recover-check`: two maps compared tag by tag, what each draws for a meaning.
extension CLI {
    /// Tag-by-tag comparison of two maps: what the original draws each meaning with,
    /// against what the rebuilt map draws it with. The full test of a style recovery -
    /// every tag, before and after.
    ///
    ///     kmap recover-check <original.img> <rebuilt.img> [--extract=FILE.pbf]...
    static func recoverCheck(_ arguments: [String]) async -> Int32 {
        let flags = Flags(arguments, valued: ["extract"])
        guard flags.positionals.count == 2 else {
            return CLIOutput.failure("usage: kmap recover-check <original.img>"
                                     + " <rebuilt.img> [--extract=FILE.pbf]…", code: 2)
        }
        let extracts = flags.values("extract").map { URL(fileURLWithPath: $0) }
        let log = Log(showing: CLIOutput.showing)
        do {
            let neutral = try await neutralRules(log: log)
            defer { FileTools.removeIfPresent(neutral) }
            let original = try await StyleRecovery.run(
                img: Paths.expand(flags.positionals[0]), extracts: extracts, log: log,
                rulesDirectory: neutral)
            let rebuilt = try await StyleRecovery.run(
                img: Paths.expand(flags.positionals[1]), extracts: extracts, log: log,
                rulesDirectory: neutral)

            func top(_ codes: [String: Int]) -> [(String, Int)] {
                let total = codes.values.reduce(0, +)
                // A code carrying under a tenth of the tag is a stray, not a mapping.
                return codes.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
                    .filter { $0.value * strayBelow >= total }
            }
            // A recovered style puts their pictures on our numbers, so where both maps
            // carry a TYP the tags are compared by picture, not by number.
            let theirTyp = typSource(of: Paths.expand(flags.positionals[0]))
            let ourTyp = typSource(of: Paths.expand(flags.positionals[1]))
            func pictures(_ codes: [(String, Int)], in typ: TypSource) -> [XpmBlock] {
                codes.compactMap { picture(of: $0.0, in: typ) }
            }

            var same = 0
            var different: [(tag: String, theirs: String, ours: String)] = []
            var missing: [(tag: String, theirs: String, count: Int)] = []
            for (tag, theirCodes) in original.codesByTag.sorted(by: { $0.key < $1.key }) {
                let witnesses = theirCodes.values.reduce(0, +)
                guard witnesses >= fewestCompared else { continue }
                let theirTop = top(theirCodes)
                let ourCodes = rebuilt.codesByTag[tag] ?? [:]
                guard !ourCodes.isEmpty else {
                    // An omission is only an omission where the rebuilt map's ground
                    // carries the tag at all: two maps over two grounds share styles,
                    // not dachas.
                    if rebuilt.groundTags[tag] ?? 0 >= fewestCompared {
                        missing.append((tag, theirTop.map(\.0).joined(separator: ","),
                                        witnesses))
                    }
                    continue
                }
                let ourTop = top(ourCodes)
                let theirs = theirTop.map(\.0).joined(separator: ",")
                let ours = ourTop.map(\.0).joined(separator: ",")
                // A settlement is drawn by the receiver itself on both maps, whatever
                // number each gives it.
                if theirTop.contains(where: { isCity($0.0) }),
                   ourTop.contains(where: { isCity($0.0) }) {
                    same += 1
                    continue
                }
                if let theirTyp, let ourTyp {
                    let wanted = pictures(theirTop, in: theirTyp)
                    let got = pictures(ourTop, in: ourTyp)
                    // Nothing painted on either side: the numbers say what agrees.
                    if wanted.isEmpty, got.isEmpty {
                        if ourTop.contains(where: { mine in theirTop.contains { $0.0 == mine.0 } }) {
                            same += 1
                        } else {
                            different.append((tag, theirs, ours))
                        }
                    } else if got.contains(where: { wanted.contains($0) }) {
                        same += 1
                    } else {
                        different.append((tag, theirs + (wanted.isEmpty ? " (unpainted)" : ""),
                                          ours + (got.isEmpty ? " (unpainted)" : "")))
                    }
                    continue
                }
                // Agreement: our commonest code for the tag is one the original uses.
                if ourTop.contains(where: { mine in theirTop.contains { $0.0 == mine.0 } }) {
                    same += 1
                } else {
                    different.append((tag, theirs, ours))
                }
            }

            CLILog.line("")
            CLILog.line("tags compared: \(same + different.count),"
                        + " agreeing \(same), differing \(different.count),"
                        + " undrawn by the rebuilt map \(missing.count)")
            for d in different {
                CLILog.line(String(format: "  DIFF  %-40@ theirs %@  ours %@",
                                   d.tag as NSString, d.theirs, d.ours))
            }
            for m in missing {
                CLILog.line(String(format: "  MISS  %-40@ theirs %@ ×%d, ours nothing",
                                   m.tag as NSString, m.theirs, m.count))
            }
            CLIOutput.result([
                "agreeing": .int(same),
                "differing": .array(different.map {
                    ["tag": .string($0.tag), "theirs": .string($0.theirs),
                     "ours": .string($0.ours)]
                }),
                "missing": .array(missing.map {
                    ["tag": .string($0.tag), "theirs": .string($0.theirs),
                     "count": .int($0.count)]
                }),
            ])
            return different.isEmpty && missing.isEmpty ? 0 : 1
        } catch {
            return CLIOutput.failure("recover-check: \(error.localizedDescription)")
        }
    }

    /// A tag is compared once this many of its objects were identified, and a code
    /// carrying under one part in this many of the tag is a stray, not a mapping.
    private static let fewestCompared = 6

    private static let strayBelow = 10

    /// The TYP a map carries, as source, or nil where it carries none.
    private static func typSource(of img: URL) -> TypSource? {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("check-\(UUID().uuidString).typ")
        defer { FileTools.removeIfPresent(scratch) }
        guard ImgContainer.extractTYP(from: img, to: scratch),
              let binary = try? TypBinary.read(scratch) else { return nil }
        return TypSource.parse(TypDecompiler.source(binary))
    }

    /// Whether an evidence key names a settlement point, `P600` and its kin.
    private static func isCity(_ key: String) -> Bool {
        guard key.first == ElementDumper.Kind.point.rawValue,
              let code = Int(key.dropFirst(), radix: 16) else { return false }
        return GarminStandard.cityTypes.contains(code)
    }

    /// What a code draws in a TYP, keyed as the evidence keys codes: `A50`, `L11f14`.
    private static func picture(of key: String, in typ: TypSource) -> XpmBlock? {
        guard let first = key.first, let kind = ElementDumper.Kind(rawValue: first),
              let code = Int(key.dropFirst(), radix: 16) else { return nil }
        // The drawing itself, a plain fill included: `picture` leaves solid ones out.
        return typ.section(kind.styleKind, code).flatMap { $0.dayXpm ?? $0.xpm }
    }
}
