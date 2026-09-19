import Foundation

/// Rules about which points reach the map and what they carry: area POIs, terrain
/// features, addresses and descriptions.
extension StyleCatalog {
    /// Lets a feature mapped as an outline get an icon: mkgmap runs the `points` rules over
    /// nodes only. Keeps the point `--add-pois-to-areas` drops in a venue, discards it for
    /// `leisure` and `man_made` and for a venue the annotate pass marked as a duplicate.
    func addAreaPOIFilter(in directory: URL, log: Log) throws {
        let marker = "# --- kmap: icons for things mapped as an outline"
        let rules = """
            \(marker) ------------------------
            # See addAreaPOIFilter. Must stay first: it works by leaving nothing behind.

            mkgmap:area2poi=true & kmap:dup_venue=yes { deletealltags }
            mkgmap:area2poi=true & amenity!=* & shop!=* & tourism!=* & office!=* \
            & healthcare!=* { deletealltags }


            """
        guard try prependRules(rules, marked: marker, toFile: "points", in: directory)
        else { return }
        log.append("outlined venues given their icons")
    }

    /// Types what a walking map needs and the stock style drops: `ford`, every shelter but
    /// `shelter_type=basic_hut`, `mountain_pass` and `natural=saddle`. Each rule supplies a
    /// default name, since almost none of these objects carry one.
    func addTerrainPOIRules(
        in directory: URL,
        cyrillic: Bool,
        log: Log
    ) throws {
        let points = directory.appendingPathComponent("points")
        guard var text = try? String(contentsOf: points, encoding: .utf8) else { return }
        let marker = "# --- kmap: terrain POIs"
        guard !text.contains(marker) else { return }

        // Almost none of these are named, so the default name carries the kind, and the
        // bracket carries it for the few that do have one.
        let words = StyleWords(cyrillic: cyrillic)
        let ford = words("terrain.ford")
        let stones = words("terrain.stones")
        let pass = words("terrain.pass")

        // Two icons: something enclosed to sit a storm out inside, against a roof on posts.
        let shelter = words("terrain.shelter")
        let hut = words("terrain.hut")
        let rock = words("terrain.rock-shelter")
        let leanTo = words("terrain.lean-to")
        let gazebo = words("terrain.gazebo")
        let picnic = words("terrain.picnic-shelter")
        let sun = words("terrain.sun-shelter")

        /// Named objects keep their name and gain the kind; unnamed ones become the kind.
        func named(
            _ condition: String,
            keep: String,
            alone: String,
            type: String
        ) -> String {
            "\(condition) & name=* { name '${name} (\(keep))' } [\(type) resolution 24]\n"
                + "\(condition) & name!=* { name '\(alone)' } [\(type) resolution 24]"
        }

        let rules = """


            \(marker) -----------------------------------------------
            # Objects the stock rule set never types at all.

            \(named("ford=stepping_stones", keep: stones, alone: "\(ford) (\(stones))",
                 type: "0x6514"))
            ford=yes | ford=stream { name '${name|def:\(ford)}' } [0x6514 resolution 24]

            mountain_pass=yes | natural=saddle { name '${name|def:\(pass)}' } [0x6613 resolution 24]

            # A bus shelter is a bus stop; a changing cabin is not shelter from anything.
            amenity=shelter & shelter_type=public_transport { delete amenity }
            amenity=shelter & shelter_type=changing_rooms { delete amenity }

            # Enclosed: somewhere to wait out weather.
            \(named("amenity=shelter & shelter_type=basic_hut", keep: hut.lowercased(),
                 alone: hut, type: "0x2b06"))
            \(named("amenity=shelter & shelter_type=weather_shelter", keep: shelter.lowercased(),
                 alone: shelter, type: "0x2b06"))
            \(named("amenity=shelter & shelter_type=rock_shelter", keep: rock,
                 alone: "\(shelter) (\(rock))", type: "0x2b06"))

            # A roof on posts.
            \(named("amenity=shelter & shelter_type=lean_to", keep: leanTo, alone: picnic,
                 type: "0x2b05"))
            \(named("amenity=shelter & shelter_type=gazebo", keep: gazebo.lowercased(),
                 alone: gazebo, type: "0x2b05"))
            \(named("amenity=shelter & (shelter_type=picnic_shelter"
                 + " | shelter_type=picnic_shelters | shelter_type=roof)",
                 keep: leanTo, alone: picnic, type: "0x2b05"))
            \(named("amenity=shelter & shelter_type=sun_shelter", keep: leanTo, alone: sun,
                 type: "0x2b05"))

            # Kind not recorded — 290 of them, so it needs to say something.
            amenity=shelter { name '${name|def:\(shelter)}' } [0x2b06 resolution 24]

            """

        splice(rules, into: &text)
        try text.write(to: points, atomically: true, encoding: .utf8)
        log.append("fords, shelters and mountain passes typed")
    }

    /// Makes address search work outside the countries `inc/address` hard-codes, by turning
    /// the `mkgmap:admin_level4...10` tags `--bounds` supplies into a city. Placed last, in
    /// the `<finalize>` section: actions are legal there and an explicit country still wins.
    func addGenericAddressRules(in directory: URL, log: Log) throws {
        let marker = "# --- kmap: generic address fallback"
        let rules = """


            \(marker) ------------------------------------
            # Derive the city and region from the boundary data for countries mkgmap has no
            # specific rule for. Each guard is `!=*`, so anything already set is left alone,
            # and the admin_level tags only exist when --bounds is supplied — without it these
            # are simply no-ops. Level 8 is the municipality nearly everywhere; 9 and 10 are
            # sub-districts, 7 and 6 the larger units to fall back on.

            mkgmap:city!=* & mkgmap:admin_level8=* { set mkgmap:city='${mkgmap:admin_level8}' }
            mkgmap:city!=* & mkgmap:admin_level9=* { set mkgmap:city='${mkgmap:admin_level9}' }
            mkgmap:city!=* & mkgmap:admin_level10=* { set mkgmap:city='${mkgmap:admin_level10}' }
            mkgmap:city!=* & mkgmap:admin_level7=* { set mkgmap:city='${mkgmap:admin_level7}' }
            mkgmap:city!=* & mkgmap:admin_level6=* { set mkgmap:city='${mkgmap:admin_level6}' }

            mkgmap:region!=* & mkgmap:admin_level4=* { set mkgmap:region='${mkgmap:admin_level4}' }
            mkgmap:region!=* & mkgmap:admin_level5=* { set mkgmap:region='${mkgmap:admin_level5}' }

            """

        var patched = 0
        for name in ["points", "lines", "polygons"] {
            try amendRuleFile(name, in: directory, unlessMarked: marker) { text in
                text += rules
                patched += 1
                return true
            }
        }
        log.append("generic address fallback added (\(patched) rule file(s))")
    }

    /// Carries OSM `description` into the object card. The format has no free-text field,
    /// so the text rides in an address field, which is shown only when an object is opened.
    /// Preference is `description:ru`, `description`, `description:en`, each excluding the
    /// others.
    func addDescriptionRules(
        in directory: URL,
        carrier: BuildRecipe.DescriptionCarrier,
        log: Log
    ) throws {
        guard carrier != .off else { return }
        let marker = "# --- kmap: descriptions"

        let rules: String
        if let tag = carrier.tag {
            rules = """


                \(marker) -------------------------------------------------
                # OSM description text, carried into the object's card on the device.
                # Address fields never draw on the map, which is the point of using one.

                description:ru=* { set \(tag)='${description:ru}' }
                description=* & description:ru!=* { set \(tag)='${description}' }
                description:en=* & description:ru!=* & description!=* { set \(tag)='${description:en}' }

                """
        } else {
            // Appended to the label instead of an address field: an address block exists
            // only on POIs, so this carrier reaches ways and areas, but is drawn on the map.
            rules = """


                \(marker) -------------------------------------------------
                # OSM description text, appended to the object's own label in brackets.

                name=* & description:ru=* { name '${name} (${description:ru})' }
                name=* & description=* & description:ru!=* { name '${name} (${description})' }
                name=* & description:en=* & description:ru!=* & description!=* \
                { name '${name} (${description:en})' }

                """
        }

        // Action-only rules with no type fall through to the rules below, annotating the
        // element rather than consuming it, and must come first to do so.
        var patched = 0
        for name in ["points", "lines", "polygons"] {
            if try prependRules(rules + "\n", marked: marker, toFile: name, in: directory) {
                patched += 1
            }
        }
        log.append(
            "descriptions carried in \(carrier.tag ?? "the name")"
                + " (\(patched) rule file(s))"
        )
    }
}
