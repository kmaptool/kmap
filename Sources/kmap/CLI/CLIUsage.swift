import Foundation

/// The help text, printed bare or on `--help`. Kept as one literal: the README tests read
/// every flag out of it, and the columns are aligned by hand.
extension CLI {
    static let usage = """
        kmap — OpenStreetMap to Garmin

          kmap                          launch the interactive interface
          kmap --version                what this build calls itself
          kmap doctor                   report on the toolchain
          kmap install [tool]           install missing tools (mkgmap, pyhgtmap)
          kmap regions [id|query]       the continents; a region's id opens it and lists its
                                        sub-regions; anything else searches
          kmap build <region-id>[+<region-id>…] [options]

        every command
          --json                        answer with one JSON object per line on stdout: the
                                        command's result, and for a build the log and the
                                        progress as they happen. Nothing else is printed —
                                        the stream carries the whole story
          --verbose                     show the detail a run normally keeps to its log
                                        file: the exact command lines, and what mkgmap and
                                        the splitter print

        build options
          A build takes only what it is given: what is not switched on is off. --profile is
          optional and switches on whatever that profile holds, in one go; a flag still
          overrides any single one of them.

          --profile=<name>              take this profile's choices as the starting point
                                        (see `kmap profiles`). Read only — no build changes
                                        a profile, or which one the interface opens on
          --style=<id>                  style id (see `kmap styles`); an id nothing answers
                                        to refuses the build rather than picking another.
                                        Without it the map carries no TYP and the device
                                        picks the colours
          --contours, --no-contours     contour lines. Off unless switched on here or by
                                        a profile — they cost an elevation download
          --dem, --no-dem               the DEM elevation layer. Off for the same reason
          --summits, --no-summits       lift the DEM at each summit to its OSM height, where
                                        the relief agrees. On with --dem unless switched off
          --interval=<metres>           contour interval, when contours are on
          --theme=all|day|night         which of the TYP's two drawings to pack. `day`
                                        leaves out every night colour, so a receiver
                                        that draws night wrongly -- an Edge 1040 does,
                                        Garmin's own maps included -- shows the day one
                                        at any hour; `night` does the reverse
          --overlap=<units>             how far past its own frame a tile may paint a
                                        shape, 0-2048 map units. Needs the mkgmap seam
                                        patch; without it the build draws no overlap
                                        whatever this says
          --land-overlap=<units>        the same for the land layer alone, which is what
                                        hides the join on a fenix and what a GPSMAP 67
                                        shows lying on its neighbour. Never more than
                                        --overlap
          --sources=<list>              elevation sources, e.g. view1,view3
          --levels=standard|smooth      zoom ladder
          --max-nodes=<n>               nodes per tile; fewer means more tiles, and mkgmap
                                        compiles one tile per core
          --parts=<n>                   cut the output into n .img files of equal weight
          --split=<fit|region|country|custom>
                                        or cut it to fit a card, by region, by country, or
                                        into exactly --parts files
          --labels=local|ru|en          which OSM name tag to label with
          --descriptions[=CARRIER]      carry OSM `description` into the object card.
                                        phone (default) stays out of the search index;
                                        street reads naturally but can reach it;
                                        region is what OpenTopoMap ships; postcode is
                                        mkgmap's own suggestion. Which one a device
                                        renders varies — try more than one.
                                        in-name puts it after the name in brackets:
                                        the only one that works on objects with no
                                        address block, and the only one drawn on the map.
                                        =off where the profile carries them and this map
                                        should not
          --zoom-plan=<name>            which rung each kind of feature starts on. Named,
                                        not by id -- `kmap profiles` lists what there is.
                                        Only the plans built for the chosen ladder apply
          --code-page=<n>|auto          1252 western Europe, 1251 Cyrillic; auto leaves it
                                        to the region, which is also how a profile that
                                        pins one is argued out of it. Wrong value silently
                                        transliterates names to Latin
          --family-id=<n>               Garmin product id; must not clash with a map
                                        already on the device (default: per region)
          --heap=<GB>                   memory for splitter and mkgmap, for this build only.
                                        Without it, what Settings works out from this machine
          --connections=<n>             download streams, 1-16, for this build only
          --memory=<GB>                 pretend the machine has this much, and run fewer
                                        lanes accordingly. Slower, and it finishes where
                                        the real amount would have swapped
          --repair-radius=<m>           how far apart two road ends may be and still be
                                        joined, 0-50 m. Default 5
          --out=<dir>                   output folder
          --work=<dir>                  scratch folder
          --keep-work                   do not delete intermediate files
          --repair-ends, --no-repair-ends
                                        close the gaps OSM left between road ends, or use
                                        the data exactly as OSM has it
          --route, --no-route           routing data
          --index, --no-index           the searchable address/POI index
          --house-numbers, --no-house-numbers
                                        house numbers in the address index
          --sea, --no-sea               generated coastlines
          --custom-pois, --no-custom-pois
                                        also write a .gpi of every object that has an OSM
                                        description — the one Garmin format with a real
                                        description field. Appears under Custom POIs
          --hide=a,b,c                  leave features off the map, instead of whatever a
                                        named profile leaves off. Ids: barriers, benches,
                                        phones, busstops. `--hide=` with nothing after it
                                        hides nothing. Reversible — rebuild to bring
                                        them back
          --word-index, --no-word-index index each word of a street name separately, so
                                        "Гагарина" finds "улица Юрия Гагарина". Costs
                                        index entries, and a slow handheld feels it.
                                        --lean-index is the old spelling of the negative

          kmap styles                   list available styles
          kmap profiles                 list the profiles --profile can name
          kmap profiles show <name>     everything one profile holds
          kmap profiles new <name> [build options]
                                        create a profile; the options are `kmap build`'s own
          kmap profiles set <name> [build options]
                                        change what a profile holds, same flags again
          kmap profiles copy <name> <new-name>
          kmap profiles rename <name> <new-name>
          kmap profiles delete <name>   the last profile stays — the build form needs one
          kmap profiles use <name>      which profile the interface opens on
          kmap hideable [filter]        list what --hide can leave off the map

        looking inside a finished map
          kmap verify <img>             check a built map before copying it to the device
          kmap coverage <img> [--step 0.25] [--quiet]
                                        whether its tiles cover the ground they claim, or
                                        leave holes that draw as blank paper
          kmap typinfo <img>            what kmap can see inside a Garmin .img
          kmap typdump <typ|img> [--polygons] [--lines] [--points] [--draw-order]
                         [--all] [--type=0xNN]
                                        decode a compiled TYP: colours, patterns, labels
                                        and the order polygons are drawn in
          kmap typgen <palette.txt> [--fid=N] [--out=FILE]
                                        write the TYP source a shipped palette stands for
          kmap extract-typ <img> [--out=DIR] [--force]
                                        pull the TYP out of a map so you can edit it.
                                        Edited copies under ~/.kmap/typ are picked up
                                        as styles and are never overwritten.
          kmap img-elements <map.img> --out <dump.bin> [--ground a,b,c,d]…
                     [--extended] [--coarse] [--res=N]
                                        dump a map's drawn elements to a binary file,
                                        the ground truth `kmap recover` reads. --coarse
                                        reads the zoomed-out levels instead of the
                                        detailed one; --res reads whatever is drawn at
                                        that resolution, wherever it lives
          kmap recover <map.img> [--extract=FILE.pbf]… [--out=STYLE.txt] [--attach]
                     [--sheet=FILE]
                                        read a foreign map against OSM ground and write its
                                        look back out as a style of kmap's own: every
                                        picture it was seen using for a meaning, on the
                                        number kmap draws that meaning with. --out writes
                                        the style, --attach puts it in the TYP library,
                                        --sheet writes the reassignment list the style
                                        editor uses.
          kmap recover-check <original.img> <rebuilt.img> [--extract=FILE.pbf]…
                                        compare two maps tag by tag — the full test of a
                                        recovery, every meaning before and after

        one piece of the pipeline, on its own
          kmap split <extract.osm.pbf> --output-dir <dir> [--mapid N]
                                        cut an extract into map tiles
          kmap contours <tile.hgt> [--step 20] [--out <file.pbf>] [--clip S,W,N,E]
                                        trace one elevation tile and report what came out;
                                        tracer diagnostics: --raw --no-split --flatness D
                                        --dump-paths F --deviation --collinear --lengths
                                        --per-level
          kmap repair-roads <in.osm.pbf> <out.osm.pbf>
                                        the annotate pass on its own: barriers, road ends,
                                        descriptions, repeated venues
          kmap burn-peaks --pbf <extract>... --hgt-dir <dir> --out <dir>
                                        raise summits in the elevation tiles to their OSM
                                        height, so the DEM and the map agree
          kmap make-gpi <extract> <out.gpi>
                                        the Custom POI file on its own
          kmap osm-scan <file.osm.pbf>  count what an extract holds
          kmap fetch-dem <area> [--source view1|view3]
                                        fetch elevation tiles without building anything
          kmap dem-cost <region>[+<region>…] [--sources=<list>]
                                        what the elevation download will weigh, per source,
                                        before any build
          kmap tif <file.tif> [--dump <out.f32>]
                                        read a GeoTIFF elevation tile
          kmap tif2hgt <cell> --dir <tiles> --out <file.hgt>
                                        turn GeoTIFF tiles into one .hgt cell

        maintaining a working copy
          kmap hideable --regenerate [--out FILE] [--points FILE]
                                        rebuild the hide catalogue from the style it is
                                        applied to
          kmap embed-assets [--assets DIR] [--out FILE]
                                        fold Assets/ back into StyleAssets.swift

          A flag naming something no one knows — a levels ladder, a carrier, a number out
          of range — refuses the build rather than falling back to a default quietly.

        Examples
          kmap build austria
          kmap build austria --parts=2 --interval=10
          kmap build austria --profile="GPSMap 67"
          kmap build monaco --no-dem --no-contours
        """
}
