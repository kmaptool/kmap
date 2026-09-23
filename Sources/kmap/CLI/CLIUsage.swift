import Foundation

/// The help text, printed bare or on `--help`. The wording is the README's, which is the
/// reference; the tests hold the two to the same set of commands and flags. Kept as one
/// literal, with the columns aligned by hand.
extension CLI {
    static let usage = """
        kmap — OpenStreetMap to Garmin

        Help and state
          kmap                          launches the interactive interface
          kmap --help                   this guide
          kmap --version                current version
          kmap doctor                   reports on the toolchain
          kmap install [tool]           installs missing tools; `kmap install java --download`
                                        fetches kmap's own JDK even where a package manager exists

        Regions and builds
          kmap regions [id|query]       no argument — the continents; a region's id opens it and
                                        lists its sub-regions; any other word searches
          kmap build <region-id>[+<region-id>…] [options]
                                        builds a map; several ids joined with + become one
                                        seamless map
          kmap dem-cost <region>[+<region>…] [--sources=<list>]
                                        what the elevation download will weigh, per source,
                                        before any build
          kmap fetch-dem <area> [--source view1|view3]
                                        fetch elevation tiles without building anything

        Flags for every command
          --json                        one JSON object per line on stdout for driving kmap from
                                        another program: the command's result, and for a build
                                        the log and the progress as they happen. Nothing else
                                        is printed
          --verbose                     shows details that usually go only to the log file

        Build options
          A command-line build does only what it is told: anything not switched on is off.
          --profile enables everything stored in a saved profile, while a flag
          overrides one specific setting. An unknown value, such as a style that doesn't exist
          or a number out of range, stops the build instead of silently replacing it with a
          default value.

          --profile=<name>              starts from this profile's settings. Read-only: no build
                                        ever changes a profile
          --style=<id>                  style id, from `kmap styles`. Without it your device
                                        uses its built-in colors
          --contours, --no-contours     contour lines
          --interval=<metres>           contour interval
          --dem, --no-dem               the DEM layer — shaded relief and the elevation profile
          --summits, --no-summits       lifts the DEM at each summit to its OSM height. On with
                                        --dem unless switched off
          --sources=<list>              elevation sources, tried in order — each fills only what
                                        the ones before it lack. Default view1,view3;
                                        copernicus1,copernicus3 is recommended (global, no
                                        login); also srtm1, alos1
          --levels=<plan>               how many zoom levels the map has: standard or smooth
          --labels=<language>           which OSM name tag to label with: local, ru or en
          --code-page=<n>               which alphabet the map keeps, a number or auto: 1252
                                        western Europe, 1251 Cyrillic; auto leaves it to the
                                        region. A wrong value silently transliterates names
                                        to Latin
          --family-id=<n>               Garmin family id; two maps with the same id hide each
                                        other
          --route, --no-route           routing data
          --repair-ends, --no-repair-ends
                                        fills gaps OSM left between road ends
          --repair-radius=<m>           how far apart two ends may be and still get joined.
                                        Default 5
          --index, --no-index           the searchable address and POI index
          --word-index, --no-word-index find a street by any word of its name.
                                        --lean-index is the old name for --no-word-index
          --house-numbers, --no-house-numbers
                                        house numbers in the address index
          --sea, --no-sea               generated coastlines
          --zoom-plan=<name>            which zoom level each kind of feature appears at, from
                                        a plan made in the interface
          --descriptions[=CARRIER]      carries OSM `description` texts into the object card:
                                        phone, street, region, postcode, in-name, or off
          --custom-pois, --no-custom-pois
                                        also write a .gpi with everything that has a
                                        description
          --hide=a,b,c                  leaves features off the map — benches, phones, power
                                        lines… ids from `kmap hideable`
          --theme=<scheme>              which of the style's two colour schemes to pack: all,
                                        day or night
          --overlap=<units>             let tiles paint a little past their frame — hides tile
                                        seams; needs the mkgmap patch (experimental)
          --land-overlap=<units>        the same for the land layer alone. Never more than
                                        --overlap
          --split=<mode>                how the output is cut into files: fit, region, country
                                        or custom
          --parts=<n>                   how many files, with --split=custom
          --max-nodes=<n>               nodes per tile; fewer nodes means more, smaller tiles
          --out=<dir>                   where the finished map goes
          --work=<dir>                  scratch folder
          --keep-work                   keeps the intermediate files
          --heap=<GB>                   memory for the compilers, this build only
          --connections=<n>             download streams, 1–16, this build only
          --memory=<GB>                 assumes the machine has this much memory and runs
                                        fewer jobs at once

        Styles and profiles
          kmap styles                   lists available styles
          kmap profiles                 lists the profiles for --profile
          kmap profiles show <name>     everything a profile holds
          kmap profiles new <name> [build options]
                                        creates a profile; the options are `kmap build`'s own
          kmap profiles set <name> [build options]
                                        changes what a profile contains, the same flags
          kmap profiles copy <name> <new-name>
          kmap profiles rename <name> <new-name>
          kmap profiles delete <name>   the last one stays, the build form needs one
          kmap profiles use <name>      which profile the interface opens on
          kmap hideable [filter]        lists what --hide can remove from the map

        Looking inside a finished map
          kmap verify <img>             checks a built map before copying it to the device
          kmap coverage <img> [--step 0.25] [--quiet]
                                        whether its tiles cover the ground they claim
          kmap typinfo <img>            what kmap can see inside a Garmin .img
          kmap typdump <typ|img> [--polygons] [--lines] [--points] [--draw-order] [--all]
                       [--type=0xNN]
                                        decodes a TYP: colours, patterns, labels, draw order
          kmap typgen <palette.txt> [--fid=N] [--out=FILE]
                                        writes out the TYP source of a built-in palette
          kmap extract-typ <img> [--out=DIR] [--force]
                                        pulls the TYP out of a map so you can reuse or edit it
          kmap recover <map.img> [--extract=FILE.pbf]… [--out=STYLE.txt] [--attach]
                       [--sheet=FILE]
                                        reads a third-party map against OSM data and writes its
                                        look back out as a style of kmap's own — its pictures
                                        on kmap's numbers. --out writes the style, --attach
                                        puts it in the TYP library, --sheet writes the
                                        reassignment list
          kmap recover-check <original.img> <rebuilt.img> [--extract=FILE.pbf]…
                                        compares two maps tag by tag — the full test of a
                                        recovery, every meaning before and after
          kmap img-elements <map.img> --out <dump.bin> [--ground a,b,c,d]… [--extended]
                       [--coarse] [--res=N]
                                        dumps a map's drawn elements, the ground `recover`
                                        reads; --coarse reads the zoomed-out levels, --res=N
                                        whatever is drawn at that resolution

        Pipeline steps individually
          kmap split <extract.osm.pbf> --output-dir <dir> [--mapid N]
                                        cut an extract into map tiles
          kmap contours <tile.hgt> [--step 20] [--out <file.pbf>] [--clip S,W,N,E]
                                        trace one elevation tile; tracer diagnostics:
                                        --raw --no-split --flatness D --dump-paths F
                                        --deviation --collinear --lengths --per-level
          kmap repair-roads <in.osm.pbf> <out.osm.pbf>
                                        the road-repair pass on its own
          kmap burn-peaks --pbf <extract> --hgt-dir <dir> --out <dir>
                                        raise summits in the elevation tiles to their OSM height
          kmap make-gpi <extract> <out.gpi>
                                        the Custom POI file on its own
          kmap osm-scan <file.osm.pbf>  count what an extract holds
          kmap tif <file.tif> [--dump <out.f32>]
                                        read a GeoTIFF elevation tile
          kmap tif2hgt <cell> --dir <tiles> --out <file.hgt>
                                        turn GeoTIFF tiles into one .hgt cell
          kmap hideable --regenerate [--out FILE] [--points FILE]
                                        rebuild the hide catalogue from the style
          kmap embed-assets [--assets DIR] [--out FILE]
                                        fold Assets/ back into the source (developers)

        Examples
          kmap build austria
          kmap build austria --parts=2 --interval=10
          kmap build austria --profile="GPSMap 67"
          kmap build monaco --no-dem --no-contours
        """
}
