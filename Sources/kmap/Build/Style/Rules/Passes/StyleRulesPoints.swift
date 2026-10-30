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
        try FileTools.write(text, to: points)
        log.append("fords, shelters and mountain passes typed")
    }

    /// Names a pass by its `rtsa_scale` category. Ahead of `inc/name`, whose `ref` rule would
    /// name it first; action-only, so the pass rule still types it.
    func addPassCategoryRules(in directory: URL, cyrillic: Bool, log: Log) throws {
        let marker = "# --- kmap: pass categories"
        let pass = StyleWords(cyrillic: cyrillic)("terrain.pass")
        let rules = """
            \(marker) --------------------------------------------
            \(Self.passCategoryRules(pass: pass, cyrillic: cyrillic))


            """
        switch try insertRules(
            rules,
            marked: marker,
            beforeLineWith: "include 'inc/name'",
            intoFile: "points",
            in: directory
        ) {
        case .added:
            log.append("mountain passes labelled with their category")
        case .missingAnchor:
            log.warn("inc/name is not included here - passes left without their category")
        case .leftAlone:
            break
        }
    }

    /// An `rtsa_scale` category, 1A to 3B or n/c, with `*` and a range, in either alphabet.
    /// Also "nc", and a range joined by a dash of any length or a `/`, spaces allowed.
    static let passCategory: String = {
        let one = "(\(passNone)|[1-3]\(passLetters.a)|[1-3]\(passLetters.b))[*]?"
        return "\(one)([ ]*[-\\u2013\\u2014/][ ]*\(one))?"
    }()

    /// n/c with its slash optional.
    private static let passNone = passLetters.none.replacingOccurrences(of: "/", with: "/?")

    /// A name that already carries a category, "Sovy 2 (1B)".
    static let passNameCategory =
        ".*(\(passLetters.none)|[1-3]\(passLetters.a)|[1-3]\(passLetters.b)).*"

    /// n/c, A and B in both alphabets and cases as character classes, since a `|` ends a `subst`.
    /// Cyrillic as `\u` escapes, which Java regex reads, so a Latin build stays ASCII.
    private static let passLetters: (none: String, a: String, b: String) = {
        let both = [StyleWords(cyrillic: false), StyleWords(cyrillic: true)]
        func escaped(_ text: String) -> String {
            text.unicodeScalars.map { $0.isASCII ? String($0) : String(format: "\\u%04X", $0.value) }
                .joined()
        }
        func pattern(_ key: String) -> String {
            let forms = both.map { Array($0(key)) }
            return forms[0].indices.map { at in
                let chars = forms.map { $0[at] }
                guard chars.contains(where: \.isLetter) else { return String(chars[0]) }
                return "[" + chars.map { escaped($0.uppercased() + $0.lowercased()) }.joined() + "]"
            }.joined()
        }
        return (pattern("terrain.pass-none"), pattern("terrain.pass-a"), pattern("terrain.pass-b"))
    }()

    /// The category in the map's alphabet, a range joined by "-" or "/" without spaces.
    static func passCategoryLabel(cyrillic: Bool) -> String {
        let words = StyleWords(cyrillic: cyrillic)
        return "${rtsa_scale|subst:[ ]*[-\\u2013\\u2014][ ]*~>-|subst:[ ]*/[ ]*~>/"
            + "|subst:\(passNone)~>\(words("terrain.pass-none"))"
            + "|subst:\(passLetters.a)~>\(words("terrain.pass-a"))"
            + "|subst:\(passLetters.b)~>\(words("terrain.pass-b"))}"
    }

    /// A pass with a category: its name, or its kind, and the category; a `ref` where
    /// `inc/name` would put it.
    static func passCategoryRules(pass: String, cyrillic: Bool) -> String {
        let condition = "(mountain_pass=yes | natural=saddle) & rtsa_scale ~ '\(passCategory)'"
        let label = passCategoryLabel(cyrillic: cyrillic)
        let named = "\(condition) & name=* & !(name ~ '\(passNameCategory)')"
        return "\(named) { name '${ref} ${name} (\(label))' | '${name} (\(label))' }\n"
            + "\(condition) & name!=* { name '\(pass) ${ref} \(label)' | '\(pass) \(label)' }"
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
    /// Preference is `description:ru`, `description`, `description:en` on a Cyrillic map,
    /// each excluding the others; elsewhere `description:en`, then `description`, as a
    /// code page without Cyrillic turns Russian text into question marks.
    func addDescriptionRules(
        in directory: URL,
        carrier: BuildRecipe.DescriptionCarrier,
        cyrillic: Bool = true,
        log: Log
    ) throws {
        guard carrier != .off else { return }
        let marker = "# --- kmap: descriptions"
        let order = cyrillic ? ["description:ru", "description", "description:en"] : ["description:en", "description"]
        /// Each tag where none before it in the order is there.
        func ladder(_ action: (String) -> String, after guardTag: String = "") -> String {
            order.enumerated().map { at, tag in
                let absent = order[..<at].map { " & \($0)!=*" }.joined()
                return guardTag + tag + "=*" + absent + " { " + action(tag) + " }"
            }.joined(separator: "\n")
        }

        var rules: String
        var labelRules: [String: String] = [:]
        if let tag = carrier.tag {
            rules = """


                \(marker) -------------------------------------------------
                # OSM description text, carried into the object's card on the device.
                # Address fields never draw on the map, which is the point of using one.

                \(ladder { "set \(tag)='${\($0)}'" })

                """
        } else {
            // Appended to the label rather than an address field, which only POIs have, so it
            // reaches ways and areas but is drawn on the map. In <finalize>, after the rules
            // that built the label: set first, it would keep a summit's height or a spring's
            // warning out. Marked, so an element drawn twice is not described twice.
            let label = "mkgmap:label:1"
            let append: (String) -> String = { "set \(label)='${\(label)} (${\($0)})'; set kmap:described=yes" }
            let unset = "\(label)=* & kmap:described!=yes & "
            // Not on a road: its first label is the number shield. A trail without a number
            // keeps its note. Nor on a summit, whose notes say where the height came from.
            let guards = [
                "points": [unset + "natural!=peak & natural!=volcano & natural!=saddle & "],
                "lines": [
                    unset + "highway!=* & ",
                    unset + "highway ~ '(path|track|footway|bridleway|steps|via_ferrata)' & ref!=* & "
                ],
                "polygons": [unset]
            ]
            rules = ""
            for (file, prefixes) in guards {
                labelRules[file] = """


                    \(marker) -------------------------------------------------
                    # OSM description text, appended to the object's own label in brackets.

                    \(prefixes.map { ladder(append, after: $0) }.joined(separator: "\n"))

                    """
            }
        }

        // An address field is set first, by action-only rules that fall through to the
        // rules below; a label is changed last, in the <finalize> section.
        var patched = 0
        for name in ["points", "lines", "polygons"] {
            if carrier.tag != nil {
                if try prependRules(rules + "\n", marked: marker, toFile: name, in: directory) { patched += 1 }
            } else {
                try amendRuleFile(name, in: directory, unlessMarked: marker) { text in
                    // The stock viewpoint puts the description in its name already.
                    text = text.replacingOccurrences(
                        of: "{name '${name} - ${description}' | '${name}'}",
                        with: "{name '${name}'}"
                    )
                    if !text.contains("\n<finalize>") { text += "\n<finalize>\n" }
                    text += labelRules[name] ?? ""
                    patched += 1
                    return true
                }
            }
        }
        log.append(
            "descriptions carried in \(carrier.tag ?? "the name")"
                + " (\(patched) rule file(s))"
        )
    }
}
