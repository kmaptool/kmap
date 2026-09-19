import Foundation

/// Rules about drinking water: sources by kind, and the variants of a spring.
extension StyleCatalog {
    /// Reclassifies natural springs tagged `amenity=drinking_water`, whose stock rule sits
    /// above the spring rules and wins. These rules only retag and assign no type, so the
    /// element carries on down the file to the spring rules, variants included.
    func addWaterSourceRules(
        in directory: URL,
        cyrillic: Bool,
        log: Log
    ) throws {
        let words = StyleWords(cyrillic: cyrillic)
        let well = words("water.well-suffix")
        let wellAlone = words("water.well")
        let tap = words("water.tap-suffix")
        let tapAlone = words("water.tap")
        let geyserAlone = words("water.geyser")
        let marker = "# --- kmap: natural water sources"
        let rules = """
            \(marker) ---------------------------------------
            # Action-only: no type, so these fall through to the spring rules below.

            amenity=drinking_water & natural=spring { delete amenity }
            amenity=drinking_water & source_ref='http://rodnik.crimea.ua/' \
            { set natural='spring'; delete amenity }

            # A well is man-made, so it keeps the tap — but it is not a tap, and the card has
            # no type row on this device, so the kind goes in the label as it does for springs.
            #
            # 0x6414 is Garmin's own well symbol, taken from a vendor style. The type is set
            # here rather than through redirects.txt because these two lines are kmap's own and
            # their text is in the map's language: a redirect keyed on one language's wording
            # matches nothing on a build in another.
            man_made=water_well & name=* { name '${name} (\(well))' } [0x6414 resolution 24]
            man_made=water_well & name!=* { name '\(wellAlone)' } [0x6414 resolution 24]
            man_made=water_tap & name=* { name '${name} (\(tap))' }
            man_made=water_tap & name!=* { name '\(tapAlone)' }

            # Neither mkgmap's stock rules nor kmap's drew a geyser at all. 0x6509 is where a
            # receiver expects one -- 0x65 is Garmin's hydrography -- and the icon is a
            # vendor style's own, on the water blue used here.
            natural=geyser & name=* { name '${name}' } [0x6509 resolution 24]
            natural=geyser & name!=* { name '\(geyserAlone)' } [0x6509 resolution 24]

            """

        switch try insertRules(
            rules,
            marked: marker,
            beforeLineWith: "amenity=drinking_water [0x5000",
            intoFile: "points",
            in: directory
        ) {
        case .added:
            log.append("natural water sources separated from taps")
        case .missingAnchor:
            log.warn(
                "the stock amenity=drinking_water rule was not found — water sources"
                    + " left as they are"
            )
        case .leftAlone:
            break
        }
    }

    /// Splits springs by what a walker needs before relying on one. All four types draw the
    /// same icon; the difference shows only in the object's card, through the TYP's type
    /// name. The rules must precede the stock `natural=spring` rule: first match wins.
    func addSpringVariantRules(
        in directory: URL,
        cyrillic: Bool,
        log: Log
    ) throws {
        let marker = "# --- kmap: spring variants"

        // Written in the language the map is labelled in: a Cyrillic suffix on a Latin map
        // comes out as question marks under code page 1252.
        let words = StyleWords(cyrillic: cyrillic)
        let spring = words("spring.name")
        let undrinkable = words("spring.undrinkable")
        let boil = words("spring.boil")
        let intermittent = words("spring.intermittent")
        let seasonal = words("spring.seasonal")

        let rules = """


            \(marker) --------------------------------------------
            # Same drawing as 0x6511, but a distinct type — and the difference is spelled into
            # the label as well. The type name alone is not enough: a GPSMAP 67 does not show
            # the type row on the map-cursor card, so a walker deciding whether to rely on this
            # water would never see it. The suffix goes on the name, which is always drawn.
            # Ordered worst-news-first: undrinkable matters more than merely seasonal.

            natural=spring & drinking_water=no \
            { name '${name|def:\(spring)} (\(undrinkable))' } [0x6517 resolution 24]
            natural=spring & drinking_water=boil \
            { name '${name|def:\(spring)} (\(boil))' } [0x6517 resolution 24]
            natural=spring & intermittent=yes \
            { name '${name|def:\(spring)} (\(intermittent))' } [0x6516 resolution 24]
            natural=spring & seasonal=yes \
            { name '${name|def:\(spring)} (\(seasonal))' } [0x6515 resolution 24]

            """
        // Immediately before the stock rule, not above `<finalize>`: first match wins, and
        // anything spliced at the end of the file loses to a rule higher up.
        switch try insertRules(
            rules.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n",
            marked: marker,
            beforeLineWith: "natural=spring [0x6511",
            intoFile: "points",
            in: directory
        ) {
        case .added:
            log.append("spring variants added to the rule set")
        case .missingAnchor:
            log.warn("the stock natural=spring rule was not found — spring variants skipped")
        case .leftAlone:
            break
        }
    }
}
