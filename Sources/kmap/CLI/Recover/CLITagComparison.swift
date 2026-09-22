import Foundation

/// Two recoveries of the same ground compared tag by tag: which tags both maps draw the
/// same way, which differently, and which the rebuilt map does not draw at all.
extension CLI {
    struct TagComparison {
        /// A tag is compared once this many of its objects were identified.
        static let fewestCompared = 6
        /// A code carrying under one part in this many of a tag is a stray, not a mapping.
        static let strayBelow = 10

        private(set) var same = 0
        private(set) var different: [(tag: String, theirs: String, ours: String)] = []
        private(set) var missing: [(tag: String, theirs: String, count: Int)] = []

        /// Where both maps carry a TYP the tags are compared by picture, not by number: a
        /// recovered style puts their pictures on our numbers.
        init(
            original: StyleRecovery.Report,
            rebuilt: StyleRecovery.Report,
            theirTyp: TypSource?,
            ourTyp: TypSource?
        ) {
            for (tag, theirCodes) in original.codesByTag.sorted(by: { $0.key < $1.key }) {
                let witnesses = theirCodes.values.reduce(0, +)
                guard witnesses >= Self.fewestCompared else { continue }
                let theirTop = Self.top(theirCodes)
                let ourCodes = rebuilt.codesByTag[tag] ?? [:]
                guard !ourCodes.isEmpty else {
                    // An omission only where the rebuilt map's ground carries the tag at
                    // all: two maps over two grounds share styles, not dachas.
                    if (rebuilt.groundTags[tag] ?? 0) >= Self.fewestCompared {
                        missing.append((tag, theirTop.map(\.0).joined(separator: ","), witnesses))
                    }
                    continue
                }
                let ourTop = Self.top(ourCodes)
                let theirs = theirTop.map(\.0).joined(separator: ",")
                let ours = ourTop.map(\.0).joined(separator: ",")
                // A settlement is drawn by the receiver itself on both maps, whatever
                // number each gives it.
                if theirTop.contains(where: { Self.isCity($0.0) }), ourTop.contains(where: { Self.isCity($0.0) }) {
                    same += 1
                    continue
                }
                let shareACode = ourTop.contains { mine in theirTop.contains { $0.0 == mine.0 } }
                if let theirTyp, let ourTyp {
                    let wanted = theirTop.compactMap { Self.picture(of: $0.0, in: theirTyp) }
                    let got = ourTop.compactMap { Self.picture(of: $0.0, in: ourTyp) }
                    // Nothing painted on either side: the numbers say what agrees.
                    if wanted.isEmpty, got.isEmpty {
                        if shareACode { same += 1 } else { different.append((tag, theirs, ours)) }
                    } else if got.contains(where: { wanted.contains($0) }) {
                        same += 1
                    } else {
                        different.append(
                            (
                                tag, theirs + (wanted.isEmpty ? " (unpainted)" : ""),
                                ours + (got.isEmpty ? " (unpainted)" : "")
                            )
                        )
                    }
                    continue
                }
                // Agreement: our commonest code for the tag is one the original uses.
                if shareACode { same += 1 } else { different.append((tag, theirs, ours)) }
            }
        }

        /// The codes carrying a tag, commonest first, the strays dropped.
        private static func top(_ codes: [String: Int]) -> [(String, Int)] {
            let total = codes.values.reduce(0, +)
            return codes.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
                .filter { $0.value * strayBelow >= total }
        }

        /// The TYP a map carries, as source, or nil where it carries none.
        static func typSource(of img: URL) -> TypSource? {
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("check-\(UUID().uuidString).typ")
            defer { FileTools.removeIfPresent(scratch) }
            guard ImgContainer.extractTYP(from: img, to: scratch),
                let binary = try? TypBinary.read(scratch)
            else { return nil }
            return TypSource.parse(TypDecompiler.source(binary))
        }

        /// Whether an evidence key names a settlement point, `P600` and its kin.
        private static func isCity(_ key: String) -> Bool {
            guard key.first == ElementDumper.Kind.point.rawValue,
                let code = Int(key.dropFirst(), radix: 16)
            else { return false }
            return GarminStandard.cityTypes.contains(code)
        }

        /// What a code draws in a TYP, keyed as the evidence keys codes: `A50`, `L11f14`.
        /// The drawing itself, a plain fill included.
        private static func picture(of key: String, in typ: TypSource) -> XpmBlock? {
            guard let first = key.first, let kind = ElementDumper.Kind(rawValue: first),
                let code = Int(key.dropFirst(), radix: 16)
            else { return nil }
            return typ.section(kind.styleKind, code).flatMap { $0.dayXpm ?? $0.xpm }
        }
    }
}
