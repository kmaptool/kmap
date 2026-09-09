import Foundation

/// Describes what the pipeline does. The text is held as whole paragraphs and wrapped to the
/// window: one paragraph is one string to translate, and a translation of it has a different
/// length.
final class HelpScreen: Screen {
    var page: Page { Page(t("help"), keys: keys) }

    private var keys: [Hint] {
        [Hint(key: "↑↓", label: t("scroll")), Hint(key: "esc", label: t("back"))]
    }

    private var scroll = 0

    /// A piece of a section: prose, or a path with what lives in it.
    private enum Block {
        case paragraph(String)
        /// A path and its description. Separate from prose: the path is neither translated
        /// nor wrapped.
        case path(String, String)
    }

    private var sections: [(String, [Block])] {
        [
            (t("what is this"), [
                .paragraph(t("Garmin devices — handhelds, watches, bike computers — can"
                           + " show detailed maps, and good ones usually cost money."
                           + " OpenStreetMap is a free map of the whole world, drawn by"
                           + " volunteers, and often more detailed than the paid ones:"
                           + " every trail, spring, bench and rain shelter.")),
                .paragraph(t("kmap turns that free map into a file your Garmin understands."
                           + " A small region builds in minutes, on your own computer."
                           + " OpenStreetMap is refined daily — rebuild the map whenever"
                           + " you want fresh data. No sign-up, and nothing is sent"
                           + " anywhere."))
            ]),
            (t("how a map is made"), [
                .paragraph(t("Pick a country, a region or a whole continent, press Build,"
                           + " and copy the finished file into the Garmin folder on the"
                           + " device or its memory card. The map lands in ~/kmap, one"
                           + " dated folder per build. A map too big for a FAT32 card"
                           + " splits itself into several files.")),
                .paragraph(t("What goes on it is a set of checkboxes on the build form:"
                           + " contour lines at the interval you choose, shaded relief with"
                           + " an elevation profile, routing and search, day and night"
                           + " colours, house numbers, labels in the local language, in"
                           + " English or in Russian. Leave out what your device does not"
                           + " need and the map gets smaller and faster."))
            ]),
            (t("your own style"), [
                .paragraph(t("Out of the box kmap draws the familiar looks of"
                           + " openstreetmap.org and OpenTopoMap. And if you own a map"
                           + " whose licence lets you reuse its style, kmap can make your"
                           + " maps look just like it: the look of a Garmin map lives in a"
                           + " small file inside it, a TYP, and kmap pulls that file out"
                           + " and works out how the map uses it.")),
                .paragraph(t("On the Styles screen, `i` imports the look from a .img or"
                           + " .typ — kmap also scans ~/Garmin and plugged-in devices."
                           + " Then `r`, recover from its map, teaches kmap which code"
                           + " that map used for a forest or a trail, by matching its"
                           + " geometry against OpenStreetMap for the same ground. After"
                           + " that, just pick the style on the build form.")),
                .paragraph(t("Styles can be copied, renamed, edited down to single icon"
                           + " pixels, and set as the default — all on the Styles screen."))
            ]),
            (t("the command line"), [
                .paragraph(t("Everything on these screens can be done from a shell, and a few"
                           + " things that cannot be done here at all. `kmap --help` lists"
                           + " every command and flag; the README has the same list in a"
                           + " table.")),
                .paragraph(t("`kmap build <region>` builds a map. `kmap verify <img>` checks"
                           + " one before it goes on the device, and `kmap coverage <img>`"
                           + " asks whether its tiles cover the ground they claim.")),
                .paragraph(t("A build takes only what it is given: what is not switched on is"
                           + " off. `--profile` switches on a whole set at once, and any"
                           + " single flag still overrides it."))
            ]),
            (t("leaving things off the map"), [
                .paragraph(t("A hide removes a rule, not data. kmap finds the rule in the"
                           + " style and replaces it with one that keeps its actions and"
                           + " loses its type, so the object stops being drawn — and rebuilding"
                           + " without the box ticked brings it back.")),
                .paragraph(t("What can be hidden is read from the style kmap is about to"
                           + " build with, so the list matches the rules a hide is applied"
                           + " to rather than a list written down somewhere else."))
            ]),
            (t("repaired road ends"), [
                .paragraph(t("Two roads can meet on screen without sharing a point — to"
                           + " the router that is a dead end. kmap joins forgotten road"
                           + " ends closer than %d m, and only where there is no way round"
                           + " at all.", Int(BuildRecipe.defaultHealRadius))),
                .paragraph(t("It never joins through a building, a fence or a hedge:"
                           + " whether a plot can be crossed is OSM's to say. Where the gap"
                           + " crosses a kerb or a step, kmap adds a thin dotted line, and"
                           + " the map shows that the gap was mended for you."))
            ]),
            (t("seams between tiles"), [
                .paragraph(t("A map is many tiles, and a receiver draws each one clipped to"
                           + " its own frame. A shape that stops at the frame leaves a hairline"
                           + " where two tiles meet — on a watch, a black seam across the"
                           + " ground.")),
                .paragraph(t("The overlap is how far past its own frame a tile may paint. It"
                           + " needs the mkgmap seam patch, which the toolchain page installs;"
                           + " without it the setting does nothing. The land layer has an"
                           + " overlap of its own, because what hides a seam on a watch shows"
                           + " as a stripe on a handheld."))
            ]),
            (t("day and night"), [
                .paragraph(t("A TYP can carry two drawings of everything: one for daylight and"
                           + " one for night. Some receivers get the night one wrong — an Edge"
                           + " 1040 does, with Garmin's own maps — and the theme setting packs"
                           + " only the one you want, so the device has nothing else to"
                           + " choose."))
            ]),
            (t("a machine with less memory"), [
                .paragraph(t("The stages that hold the most run fewer lanes where there is not"
                           + " room for all of them, and say so. Slower, and it finishes:"
                           + " a build that starts swapping is slower than one that ran a lane"
                           + " at a time.")),
                .paragraph(t("`--memory=<GB>` says the machine has less than it does, which is"
                           + " how to leave room for everything else while a map builds."))
            ]),
            (t("contours are not the DEM"), [
                .paragraph(t("Contour lines are vector ways generated from elevation data and"
                           + " drawn on the map like any other line. The DEM layer is a raster"
                           + " elevation grid stored in the map, and it is what gives shaded"
                           + " relief and the elevation profile. They are independent — you"
                           + " can have either, both, or neither. Both come from the same"
                           + " downloaded .hgt tiles, so enabling both costs one download."))
            ]),
            (t("about \"10 m\""), [
                .paragraph(t("A 10 m contour interval is a choice you make and kmap honours"
                           + " it. It is not the same as a 10 m resolution elevation model:"
                           + " freely available global elevation data is 1 arc-second, roughly"
                           + " 30 m on the ground. A 10 m interval drawn from 30 m data is"
                           + " normal practice and looks right in the mountains, but on flat"
                           + " ground the lines will wander. Nothing kmap can do about that —"
                           + " the data does not exist."))
            ]),
            (t("profiles"), [
                .paragraph(t("A profile is a named set of build choices — the whole build"
                           + " screen except the region. Make one per device, or per kind of"
                           + " map, and pick it at the top of the build screen: it fills the"
                           + " form in, and the one picked last is the one the next map opens"
                           + " on.")),
                .paragraph(t("Changing a field afterwards changes that map only, and says so"
                           + " on the profile row. Nothing else on the build screen is written"
                           + " down — a profile is rewritten from the profile screen and"
                           + " nowhere else, which is what makes it safe to build from.")),
                .paragraph(t("What a profile does not hold: the region, the family id and the"
                           + " output folder. The first two belong to one map, and the folder"
                           + " is set once in Settings. It can also leave the code page to the"
                           + " region, which is usually right: the same profile then builds a"
                           + " Cyrillic map as 1251 and a German one as 1252."))
            ]),
            (t("styles and TYP files"), [
                .paragraph(t("How a Garmin map looks is decided by its TYP file, which mkgmap"
                           + " embeds verbatim. That means any .typ you already own can be"
                           + " reused as the look for your own maps — kmap scans your Garmin"
                           + " folders and offers what it finds. The catch is that a TYP styles"
                           + " Garmin type codes, and it was written against whatever rule set"
                           + " its author used; if that differs from mkgmap's, some types will"
                           + " fall back to device defaults. The family id has to match too,"
                           + " and kmap reads it out of the TYP for you."))
            ]),
            (t("code page"), [
                .paragraph(t("The code page decides which alphabet survives into the map. 1252"
                           + " covers western Europe, 1251 covers Cyrillic. It also overrides"
                           + " the code page declared inside the TYP: get it wrong and"
                           + " localized labels are dropped silently, with no warning."))
            ]),
            (t("the language of the interface"), [
                // The interface language and the map's label language are unrelated.
                .paragraph(t("The language kmap speaks is chosen in Settings and is nothing to"
                           + " do with the map. What language a road is labelled in on the"
                           + " device is decided by Labels and the code page on the build"
                           + " screen, per map. Switching the interface to Russian does not"
                           + " change one byte of a built map."))
            ]),
            (t("splitting the output"), [
                .paragraph(t("Large regions can be written as several .img files, split along"
                           + " whichever axis the region is widest on. Each file installs"
                           + " separately, and all of them share one family id so the same TYP"
                           + " applies to every part."))
            ]),
            (t("installing a map"), [
                .paragraph(t("Copy the .img to the Garmin folder on the device or its SD card."
                           + " To keep several maps side by side, give each a distinct"
                           + " filename — the device reads them all."))
            ]),
            (t("where things live"), [
                .path("~/.kmap/cache/pbf", t("downloaded extracts, reused between builds")),
                .path("~/.kmap/cache/hgt", t("elevation tiles, shared by contours and the DEM")),
                .path("~/.kmap/styles", t("the rule set and TYP sources")),
                .path("~/.kmap/typ", t("your TYP library — the styles you may edit")),
                .path("~/.kmap/work", t("intermediate tiles, removed unless you keep them")),
                .path("~/.kmap/logs", t("the full output of every build"))
            ])
        ]
    }

    func handle(_ key: KeyEvent, ctx: AppContext) -> Route {
        switch key {
        case .up, .char("k"): scroll = max(0, scroll - 1)
        case .down, .char("j"): scroll += 1
        case .pageUp: scroll = max(0, scroll - 10)
        case .pageDown: scroll += 10
        case .home: scroll = 0
        case .esc: return .pop
        case .ctrl("c"): return .quit
        default: break
        }
        return .none
    }

    /// The page flattened into lines, held until the language or the width changes, so the
    /// translations and the wrap are not redone every frame.
    private var flattened: (language: String, width: Int, lines: [(String, Style)])?

    private func lines(width: Int, theme: Theme) -> [(String, Style)] {
        let language = L10n.current.rawValue
        if let held = flattened, held.language == language, held.width == width {
            return held.lines
        }
        // Flattened into renderable lines, so scrolling is an index into the array.
        var lines: [(String, Style)] = []
        let body = Style(fg: theme.text, bg: theme.appBg)
        let pathColumn = 22

        for (caption, blocks) in sections {
            lines.append((caption.uppercased(),
                          Style(fg: theme.accent, bg: theme.appBg, bold: true)))
            for block in blocks {
                switch block {
                case .paragraph(let text):
                    for chunk in wrapText(text, width: width) { lines.append((chunk, body)) }
                case .path(let where_, let what):
                    let left = where_.padding(toLength: pathColumn, withPad: " ", startingAt: 0)
                    lines.append((left + what, body))
                }
                lines.append(("", theme.base))
            }
        }
        flattened = (language, width, lines)
        return lines
    }

    func render(into s: Surface, rect: Rect, ctx: AppContext) {
        let theme = ctx.theme
        let lines = lines(width: rect.w, theme: theme)

        scroll = max(0, min(scroll, max(0, lines.count - rect.h)))
        let end = min(lines.count, scroll + rect.h)

        for (i, index) in (scroll..<end).enumerated() {
            let (text, style) = lines[index]
            s.text(rect.x, rect.y + i, truncate(text, to: rect.w), style)
        }

        if lines.count > rect.h {
            Widgets.scrollHint(s, rect: rect, offset: scroll,
                               count: lines.count, visible: rect.h, theme: theme)
        }
    }
}
