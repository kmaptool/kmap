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

        /// What a code shows on a map: a picture of the style's, nothing at all, or
        /// whatever the receiver draws a number the style has no section for.
        private enum Look: Equatable {
            case picture(XpmBlock)
            case clear
            case device

            var picture: XpmBlock? {
                if case .picture(let block) = self { return block }
                return nil
            }
        }

        /// Where both maps carry a TYP the tags are compared by what is seen, not by
        /// number: a recovered style puts their pictures on our numbers. A tag neither
        /// map shows agrees, whatever the numbers; one the receiver draws on both agrees
        /// where it draws the same number.
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
                let ourTop = Self.top(rebuilt.codesByTag[tag] ?? [:])
                // Compared only where the rebuilt map's ground carries the tag at all:
                // 2 maps over 2 grounds share styles, not dachas.
                if ourTop.isEmpty, (rebuilt.groundTags[tag] ?? 0) < Self.fewestCompared { continue }
                let theirs = theirTop.map(\.0).joined(separator: ",")
                let ours = ourTop.map(\.0).joined(separator: ",")
                // A settlement is drawn by the receiver itself on both maps, whatever
                // number each gives it.
                if theirTop.contains(where: { Self.isCity($0.0) }), ourTop.contains(where: { Self.isCity($0.0) }) {
                    same += 1
                    continue
                }
                let shareACode = ourTop.contains { mine in theirTop.contains { $0.0 == mine.0 } }
                guard let theirTyp, let ourTyp else {
                    // Agreement: our commonest code for the tag is one the original uses.
                    if ourTop.isEmpty {
                        missing.append((tag, theirs, witnesses))
                    } else if shareACode {
                        same += 1
                    } else {
                        different.append((tag, theirs, ours))
                    }
                    continue
                }
                let wanted = theirTop.map { (code: $0.0, look: Self.look(of: $0.0, in: theirTyp)) }
                let got = ourTop.map { (code: $0.0, look: Self.look(of: $0.0, in: ourTyp)) }
                if Self.agree(wanted, got) {
                    same += 1
                } else if ourTop.isEmpty {
                    missing.append((tag, theirs, witnesses))
                } else {
                    different.append((tag, theirs + Self.note(wanted), ours + Self.note(got)))
                }
            }
        }

        /// A picture both sides draw settles it. With no picture on either side, both
        /// show nothing, or the receiver draws a number they share. A tag the rebuilt
        /// map leaves out shows nothing.
        private static func agree(_ wanted: [(code: String, look: Look)], _ got: [(code: String, look: Look)]) -> Bool {
            let theirs = wanted.compactMap(\.look.picture)
            let ours = got.compactMap(\.look.picture)
            guard theirs.isEmpty, ours.isEmpty else { return ours.contains { theirs.contains($0) } }
            let theirDevice = wanted.filter { $0.look == .device }.map(\.code)
            let ourDevice = got.filter { $0.look == .device }.map(\.code)
            if theirDevice.isEmpty || ourDevice.isEmpty { return theirDevice.isEmpty && ourDevice.isEmpty }
            return ourDevice.contains { theirDevice.contains($0) }
        }

        /// What a side with no picture is printed with.
        private static func note(_ side: [(code: String, look: Look)]) -> String {
            if side.contains(where: { $0.look.picture != nil }) { return "" }
            return side.contains { $0.look == .device } ? " (unpainted)" : " (clear)"
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
            guard let (kind, code) = StylePort.read(key), kind == .point else { return false }
            return GarminStandard.cityTypes.contains(code)
        }

        /// What a code shows under a TYP, keyed as the evidence keys codes: `A50`,
        /// `L11f14`. A line or an area whose section draws nothing is clear, and so is
        /// an area the draw order leaves out; a blank icon is a look of its own, the
        /// name alone.
        private static func look(of key: String, in typ: TypSource) -> Look {
            guard let (kind, code) = StylePort.read(key) else { return .device }
            // An area missing from the draw order is not drawn, section or none.
            if kind == .polygon, !typ.drawOrder.isEmpty, !typ.drawOrder.contains(where: { $0.code == code }) {
                return .clear
            }
            guard let section = typ.section(kind, code) else { return .device }
            guard kind == .point || StylePort.draws(section) else { return .clear }
            return (section.dayXpm ?? section.xpm).map { .picture($0) } ?? .device
        }
    }
}
