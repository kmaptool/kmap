import Foundation

/// Rules about barriers across a way: who may pass, and how a closed one is drawn.
extension StyleCatalog {
    /// Names each barrier in the map's own language and says when it cannot be passed,
    /// both through the barrier's label. The name is set here, not appended later: `add
    /// name=` below is a no-op once a name exists. These rules carry no type of their own.
    func addBarrierAccessRules(
        in directory: URL,
        cyrillic: Bool,
        log: Log
    ) throws {
        let marker = "# --- kmap: barrier access"

        let words = StyleWords(cyrillic: cyrillic)
        let tags = [
            "gate", "lift_gate", "swing_gate", "kissing_gate", "bollard",
            "block", "cycle_barrier", "stile", "chain", "bus_trap"
        ]
        let locked = words("barrier.locked")
        let noEntry = words("barrier.no-entry")
        let priv = words("barrier.private")

        var lines = [
            "", "", "\(marker) ----------------------------------------------",
            "# Action-only: the barrier still falls through to the type rules below.",
            ""
        ]
        for tag in tags {
            let base = "${name|def:\(words("barrier.\(tag)"))}"
            lines.append("barrier=\(tag) & locked=yes { name '\(base) (\(locked))' }")
            lines.append(
                "barrier=\(tag) & locked!=yes & access=no"
                    + " { name '\(base) (\(noEntry))' }"
            )
            lines.append(
                "barrier=\(tag) & locked!=yes & access!=no & foot=no"
                    + " { name '\(base) (\(noEntry))' }"
            )
            lines.append(
                "barrier=\(tag) & locked!=yes & access=private & foot!=yes"
                    + " { name '\(base) (\(priv))' }"
            )
            lines.append("barrier=\(tag) { name '\(base)' }")
        }
        lines.append("")

        // Above the barrier type block, not at the end of the file: that block assigns a
        // type, so it consumes the barrier and nothing after it would ever be reached.
        switch try insertRules(
            lines.joined(separator: "\n") + "\n\n",
            marked: marker,
            beforeLineWith: Self.barrierBlockNote,
            intoFile: "points",
            in: directory
        ) {
        case .added:
            log.append("barriers named in the map's language, with access noted")
        case .missingAnchor:
            log.warn("the barrier block was not found — barrier access left unlabelled")
        case .leftAlone:
            break
        }
    }

    /// One barrier rule's condition line. The contexts stay mutually exclusive: a rule
    /// stripped of its type keeps its actions and continues, so an overlap would
    /// re-draw what a hide removed.
    static func barrierCondition(_ barriers: String, context: String?) -> String {
        context.map { "(\(barriers)) & kmap:on=\($0)" }
            ?? "(\(barriers)) & kmap:on!=path & kmap:on!=minor & kmap:on!=fence"
    }

    /// The action line under it: the barrier's kind as its name, and the number.
    static func barrierAction(code: Int) -> String {
        "    {add name='${barrier|subst:\"_=> \"}'} [0x\(String(code, radix: 16)) resolution 24]"
    }

    /// Splits mkgmap's one barrier rule by context, so each can be hidden on its own,
    /// and by group, so each wears its own number. The hide catalogue names these
    /// lines byte for byte, from the same definitions.
    func splitBarrierRule(in directory: URL, log: Log) throws {
        let points = directory.appendingPathComponent("points")
        guard var text = try? String(contentsOf: points, encoding: .utf8) else { return }

        let original = """
            barrier=bollard | barrier=bus_trap | barrier=gate | barrier=block | barrier=cycle_barrier |
                barrier=stile | barrier=kissing_gate | barrier=lift_gate | barrier=swing_gate
                {add name='${barrier|subst:"_=> "}'} [0x3200 resolution 24]
            """
        guard text.contains(original) else { return }

        var split = [Self.barrierBlockNote]
        for context in Self.barrierContexts {
            for group in Self.barrierGroups {
                split.append(Self.barrierCondition(group.barriers, context: context))
                split.append(Self.barrierAction(code: group.code))
            }
        }
        text = text.replacingOccurrences(of: original, with: split.joined(separator: "\n"))
        try FileTools.write(text, to: points)
        log.append("barrier rule split by context and into gates, booms and bollards")
    }
}
