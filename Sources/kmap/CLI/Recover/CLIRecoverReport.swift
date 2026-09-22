import Foundation

/// A recovery reported: on screen, as data, and what was left over on either side.
extension CLI {
    /// The status column of an outcome line.
    private static let outcomeStatusColumn = 14
    /// The kind column of a contested or uncovered line.
    private static let kindColumn = 8
    /// Most uncovered codes listed by hand; the data carries them all.
    private static let mostUncoveredShown = 40

    /// The frame and one line per code. The reassignment list is written only where
    /// `--sheet` asks for it.
    static func printRecovery(
        _ report: StyleRecovery.Report,
        ordered: [StyleRecovery.Outcome],
        sheet: String?
    ) throws {
        CLILog.line("")
        CLILog.line("frame     \(report.frame.display)")
        CLILog.line("extracts  \(report.extracts.map(\.lastPathComponent).joined(separator: ", "))")
        CLILog.line("elements  \(report.elements)")
        CLILog.line("")
        for o in ordered {
            let code = String(format: "%@ 0x%05x", String(o.kind.rawValue), o.type)
            CLILog.line(
                "\(code)  \(o.status.rawValue.padding(toLength: outcomeStatusColumn, withPad: " ", startingAt: 0))"
                    + " witnesses=\(o.witnesses)/\(o.elements)"
                    + (o.zooms.map { " " + $0 } ?? "")
                    + (o.meaning.isEmpty ? "" : "  \(o.meaning)")
            )
        }
        if let sheet {
            try (report.sheet + "\n").write(to: Paths.expand(sheet), atomically: true, encoding: .utf8)
            CLILog.line("\nsheet -> \(sheet)")
        }
    }

    /// What did not map cleanly: one number of ours that several looks of theirs wanted,
    /// where a rule of ours lumps together what their style tells apart; and what their
    /// style draws that kmap has no number for, the list that says where the rule base
    /// wants widening.
    static func printLeftovers(_ report: StyleRecovery.Report) {
        if !report.contested.isEmpty {
            CLILog.line("")
            CLILog.line("one number of ours, several looks of theirs (the winner first):")
            for port in report.contested {
                let rivals = port.rivals.map {
                    "\($0.meaning) <- 0x\(String($0.theirs, radix: 16)) (\($0.witnesses))"
                }.joined(separator: ", ")
                CLILog.line(
                    "  \(kindCell(port.kind)) 0x\(String(port.ours, radix: 16))"
                        + "  \(port.meaning) <- 0x\(String(port.theirs, radix: 16))"
                        + " (\(port.witnesses))  over  \(rivals)"
                )
            }
        }
        guard !report.uncovered.isEmpty else { return }
        CLILog.line("")
        CLILog.line("their style draws these, and kmap's rules have no number for them:")
        for entry in report.uncovered.prefix(mostUncoveredShown) {
            CLILog.line(
                "  \(kindCell(entry.kind)) 0x\(String(entry.theirs, radix: 16))"
                    + "  \(entry.meaning) — \(entry.witnesses) seen"
            )
        }
        if report.uncovered.count > mostUncoveredShown {
            CLILog.line("  … and \(report.uncovered.count - mostUncoveredShown) more")
        }
    }

    private static func kindCell(_ kind: MapElementKind) -> String {
        kind.rawValue.padding(toLength: kindColumn, withPad: " ", startingAt: 0)
    }

    /// The same recovery in the structured shape.
    static func reportRecoveryJSON(
        _ report: StyleRecovery.Report,
        ordered: [StyleRecovery.Outcome],
        path: String,
        out: String?
    ) {
        CLIOutput.result([
            "map": .string(Paths.expand(path).path),
            "frame": frameAsData(report.frame),
            "extracts": .array(report.extracts.map { .string($0.path) }),
            "elements": .int(report.elements),
            "outcomes": .array(
                ordered.map { outcome in
                    [
                        "kind": .string(String(outcome.kind.rawValue)),
                        "type": .int(outcome.type),
                        "hex": .string(String(format: "0x%05x", outcome.type)),
                        "status": .string(outcome.status.rawValue),
                        "witnesses": .int(outcome.witnesses),
                        "elements": .int(outcome.elements),
                        "unmatched": .int(outcome.unmatched),
                        "ambiguous": .int(outcome.ambiguous),
                        "meaning": .string(outcome.meaning)
                    ]
                }
            ),
            "sheet": .string(report.sheet),
            "contested": .array(
                report.contested.map { port in
                    [
                        "kind": .string(port.kind.rawValue), "ours": .int(port.ours),
                        "theirs": .int(port.theirs), "meaning": .string(port.meaning),
                        "witnesses": .int(port.witnesses),
                        "rivals": .array(
                            port.rivals.map {
                                [
                                    "theirs": .int($0.theirs), "meaning": .string($0.meaning),
                                    "witnesses": .int($0.witnesses)
                                ]
                            }
                        )
                    ]
                }
            ),
            // The whole list, where the printed one stops short.
            "uncovered": .array(
                report.uncovered.map { entry in
                    [
                        "kind": .string(entry.kind.rawValue),
                        "theirs": .int(entry.theirs),
                        "hex": .string(String(format: "0x%05x", entry.theirs)),
                        "meaning": .string(entry.meaning),
                        "witnesses": .int(entry.witnesses)
                    ]
                }
            ),
            "out": .of(out)
        ])
    }

    static func frameAsData(_ frame: BBox) -> JSONValue {
        [
            "minLat": .double(frame.minLat),
            "minLon": .double(frame.minLon),
            "maxLat": .double(frame.maxLat),
            "maxLon": .double(frame.maxLon)
        ]
    }
}
