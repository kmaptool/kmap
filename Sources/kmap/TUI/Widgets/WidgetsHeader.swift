import Foundation

/// The header's right-hand side and the spinner every waiting screen turns.
extension Widgets {
    /// The right-hand header pieces, right to left, each with the column it ends at. The
    /// clock is always present; the load figures are dropped where they would reach the
    /// title.
    static func headerRight(
        width: Int,
        titleEnds: Int,
        clock: String,
        load: MachineLoad
    ) -> [(text: String, endsAt: Int)] {
        var out = [(clock, width - 2)]
        var edge = width - 2 - clock.count - 2

        let memory = load.totalMemory > 0 ? Fmt.memory(used: load.usedMemory, total: load.totalMemory) : ""
        let cpu = load.cpu.map { t("cpu %d%%", Int(($0 * 100).rounded())) } ?? ""
        // Memory and CPU are shown together or not at all.
        let needed = [memory, cpu].filter { !$0.isEmpty }.reduce(0) { $0 + $1.count + 2 }
        guard needed > 0, edge - needed > titleEnds + 2 else { return out }

        if !memory.isEmpty {
            out.append((memory, edge))
            edge -= memory.count + 2
        }
        if !cpu.isEmpty {
            out.append((cpu, edge))
        }
        return out
    }

    static func spinner(_ frame: Int) -> Character {
        Glyph.spinner[(frame / Glyph.spinnerTicksPerFrame) % Glyph.spinner.count]
    }
}
