import Foundation

extension StyleRecovery.Remainder {
    /// What the ground read showed of a code it left unsettled.
    struct Sighting: Equatable {
        /// Its elements at the detail level on the ground read; 0 for a code drawn only
        /// off it, or only zoomed out.
        var elements = 0
        /// Its witnesses, those of the zoomed-out levels with the rest.
        var sources = 0
        /// The witnesses that meant anything.
        var meant = 0
        /// Left for witnesses that disagree, not for too few of them.
        var mixed = false

        /// Whether a region drawing the code `drawn` times may settle it, read as the
        /// ground was: identified as often, and meaning as much. That has to bring 1
        /// sighting more, and enough of them in all to witness. Witnesses that disagree,
        /// or half of them meaning nothing, stay so however many more of the same come.
        func maySettle(drawn: Int) -> Bool {
            let fewest = StyleRecovery.fewestWitnesses
            guard !mixed, meant * 2 >= sources else { return false }
            // No rate to go by: never drawn on the ground read, or nothing identified in
            // too few elements to witness. Drawn often enough to witness is a chance.
            if elements == 0 || (sources == 0 && elements < fewest) { return drawn >= fewest }
            // An element is 1 sighting at most, whatever the zoomed-out levels added.
            let seen = min(meant, elements)
            return drawn * seen >= elements && seen * (elements + drawn) >= fewest * elements
        }
    }
}
