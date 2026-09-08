import Foundation

/// The ladder a map is drawn on, as the rungs a rule can actually sit on. mkgmap's
/// `--levels` list names the bits of each rung and is written into every tile's TRE
/// header. A rule's `resolution` is a threshold rather than a rung: it lands on the
/// coarsest rung with at least that many bits, so one step means one rung, not one bit.
struct ZoomRungs {
    /// Bits per rung, finest first -- the order mkgmap's own `--levels` string uses.
    let bits: [Int]

    /// Reads the `--levels` string: `0:24, 1:23, …`. Anything unreadable is left out
    /// rather than guessed at, and an empty ladder makes every move a no-op.
    init(levels: String) {
        bits = levels.split(separator: ",").compactMap { entry in
            entry.split(separator: ":").last.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        }
    }

    init(bits: [Int]) { self.bits = bits }

    var isEmpty: Bool { bits.isEmpty }

    /// The rung a rule written for `resolution` actually appears on: mkgmap draws the
    /// element on every rung with at least that many bits, so the rung that matters is
    /// the coarsest of them. Nil when no rung is fine enough, the rule then drawing nowhere.
    func rung(forResolution resolution: Int) -> Int? {
        // Finest first, so the LAST rung with enough bits is the coarsest that carries it.
        bits.lastIndex { $0 >= resolution }
    }

    /// The bits to write as the resolution for a rung. Clamped: a move past either end
    /// stops at the end rather than falling off the ladder.
    func resolution(atRung rung: Int) -> Int? {
        guard !bits.isEmpty else { return nil }
        return bits[max(0, min(bits.count - 1, rung))]
    }

    /// Where `resolution` ends up after moving `steps` rungs; positive is coarser.
    /// - Returns: nil when the result is the resolution it already had.
    func moved(_ resolution: Int, by steps: Int) -> Int? {
        guard steps != 0, let from = rung(forResolution: resolution),
              let to = self.resolution(atRung: from + steps), to != resolution
        else { return nil }
        return to
    }

    /// The scale label without its space, to fit a column six characters wide.
    static func shortScale(bits: Int) -> String? {
        scale(bits: bits)?.replacingOccurrences(of: " ", with: "")
    }

    /// How far a rung is from the eye, as a translated label: unit and decimal mark both
    /// change with the language. Only measured rungs are named; the rest are nil rather
    /// than interpolated.
    static func scale(bits: Int) -> String? {
        switch bits {
        case 24: return t("300 m")
        case 23: return t("600 m")
        case 22: return t("1.2 km")
        case 21: return t("3 km")
        case 19: return t("5 km")
        default: return nil
        }
    }
}
