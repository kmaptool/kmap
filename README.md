<div align="center">

# 🗺 kmap

**kmap is a computer program for building free detailed maps compatible with all Garmin
navigation devices and smartwatches.**

You can build maps directly on your computer in just a few minutes. Select a country or a
region, press Build, and copy a single `.img` file to your Garmin device. A new map is
ready to use immediately.

[По-русски → README.ru.md](README.ru.md)

![Windows · Linux · macOS](https://img.shields.io/badge/Windows_·_Linux_·_macOS-supported-4c9)
![licence MIT](https://img.shields.io/badge/licence-MIT-blue)
![built with Swift](https://img.shields.io/badge/built_with-Swift-F05138)
![no accounts, no cloud](https://img.shields.io/badge/no_accounts-no_cloud-8a2be2)
![fast](https://img.shields.io/badge/fast-every_core_·_everything_cached-orange)

</div>

```text
 kmap · new map · Europe                                       22:57:14
 ──────────────────────────────────────────────────────────────────────
 › Profile          GPSMap 67         │ REGION ────────────────────────
                                      │ Europe   34.92 GB
   Style            opentopomap       │
   Contour lines    on                │ COST ──────────────────────────
   Interval         20 m              │ about 62.51 GB to download
   DEM layer        on                │
   Zoom plan        Smooth (8 levels) │ OUTPUT FOLDER ─────────────────
   Labels           Local             │ 2026-09-05_europe_20m_dem
   Routable         on                │
   Search index     on                │ PROFILE ───────────────────────
   House numbers    on                │ GPSMap 67
   Hide on map      Gates in fences…  │
                                      │
   Build map ⏎                        │
 ──────────────────────────────────────────────────────────────────────
  ↑↓ field   ←→ change   ⏎ open · build   esc back           kmap 1.0.0
```

## The problem kmap solves

Good maps for Garmin devices not only cost money as a rule, but are also rarely updated.
kmap saves money and time by making it possible to create free detailed maps of any region
or area yourself, as well as easily customize them to your needs without long data
processing.

## How it works

kmap uses [OpenStreetMap](https://www.openstreetmap.org) data: a free map of the whole
world that volunteers update every day, adding little-known trails, springs, shelters,
etc., that even paid maps often lack.

Building runs directly on your computer and requires a couple of minutes for a small area.
OpenStreetMap data is updated daily, just rebuild the map when you need it.

kmap is as fast as possible. The program utilizes all CPU cores, all data is downloaded
concurrently. Automatic resuming after disconnection is also supported. Downloaded data is
cached. Re-building the map starts within a few seconds.

## Why kmap

- It's free of charge. No subscription, no sign-up.
- Fast operation. Building a map requires a few minutes.
- Privacy protection. The program runs on your computer (Windows, Mac, or Linux) and sends
  no personal data anywhere.
- Flexible customization. See [What's on the map](#whats-on-the-map) for more details.
- Route repair. kmap fills small (up to 5 m or 16 ft) road and trail gaps to ensure
  correct route plotting.
- Seamless maps. Select several regions or countries at once and merge them into one map.
- Style import. kmap makes it possible to use graphic features (a TYP file) of any Garmin
  map you have to create new ones. See [Your own map style](#your-own-map-style).

## 3 steps to build your own map

1. **Install kmap**. A build for your system is [here](#installation).
2. **Run `kmap`**, select a country, a region, or an entire continent, press **Build**. On
   the first run, kmap asks to download a few tools it needs. Confirm the download, and
   the program performs the rest automatically.
3. **Copy the resulting file** into the `Garmin` folder on the device or its memory card.

> [!TIP]
> Unsure about your configuration? `kmap doctor` runs a diagnostic and guides you through
> the required changes.

## What's on the map

- **Contour lines**. Fine elevation contour lines, allowing hikers to read the slopes with
  a contour interval of your choice.
- **Hillshading**. Soft shadows that make mountains look like mountains, plus an elevation
  profile for your route.
- **Route planning** and **search** by address or place name.
- **Day and night modes**, house numbers, coastlines, and points of interest.
- **Labels in local language**, English or Russian, as you prefer.

Each of these features can be selected in the settings before building a new map. If your
device requires a smaller one to work faster, just disable unnecessary options.

---

*Moving forward, the guide takes you from everyday usage to advanced configuration:*
**[styles](#your-own-map-style) · [profiles](#profile-for-any-device) ·
[coverage](#coverage) · [installation](#installation) · [command line](#command-line) ·
[good to know](#good-to-know) · [for developers](#for-developers)**

## Interface and command line

There are two ways to use kmap: through the full-screen TUI or from the command line for
scripting and automation. Both of them offer the same capabilities. This guide covers both
approaches.

| 🖥 Interface | ⌨️ Command line |
|---|---|
| Run `kmap` | |
| Select a region | Enter a region: `kmap build austria` |
| Select a profile, enable or disable options for a particular map | `--profile="GPSMap 67"`, and any flags on top |
| Press **Build** and watch the progress | The same progress, but in the terminal |

Either way, a new map will be saved to `~/kmap`. Just copy it to your device.

## Your own map style

By default, kmap builds a map using the standard OpenStreetMap or OpenTopoMap design,
simply select one of these options. However, there is more. **If you have a map with a
license that permits design reuse, you can apply ready-made styles to your new maps.**

| | 🖥 Interface | ⌨️ Command line |
|---|---|---|
| **1 · Get a ready-made design file** | Open **Styles**, press `i`, select `.img` or `.typ`, kmap also scans `~/Garmin` and any plugged-in device, so the needed file on the memory card will be found automatically | `kmap extract-typ my-map.img` |
| **2 · Recover the map design** | It is offered right after the import. Or open a style and press `r`, *recover from its map* to get a TYP file that can be applied to a new map | `kmap recover my-map.img --attach` |
| **3 · Build a new map with an applied style** | Select the necessary style | `kmap build … --style=typ:my-map` |

The design of a Garmin map is stored in a small file inside it (a TYP file). kmap can pull
that file out and use it when building a new map. Usually, no editing is needed.

### Style import

A TYP file stores the codes of all objects, but it does not contain information about
which code corresponds to which object on a particular map. kmap automatically matches the
map geometry with OpenStreetMap data. The result is stored alongside the imported TYP
file, and each subsequent build using this style will look identical or very close to the
original map, from which it was pulled.

All design adjustment operations are performed on the **Styles** screen. You can copy
existing styles, rename them, set as default, and modify each parameter, up to editing any
icon pixel by pixel.

## Profile for any device

Some Garmin devices may need different versions of the same map, for example, the most
detailed one for a handheld, a lighter one for a smartwatch, one without a night mode for
a cycling computer, etc. Just create a separate **profile** (build settings) for each of
your devices.

A profile bar is shown at the top of the build form. Once a profile is selected, the
settings are applied automatically. Further changes to parameters affect only the current
build and leave the saved profile unchanged.

| 🖥 Interface | ⌨️ Command line |
|---|---|
| **Profiles** screen: `n` new, `c` copy, `r` rename, `d` delete, `m` select as current | `kmap profiles new/copy/rename/delete/use <name>` |
| Edit profile fields on the profile form | `kmap profiles set <name> --interval=25 --no-dem …` provides the same flags as for `kmap build` |
| Check profile settings | `kmap profiles` lists all profiles, `kmap profiles show <name>` opens one of them |
| Select a profile from the top bar of the build form | `kmap build … --profile="GPSMap 67"` |

## Coverage

kmap uses the same region tree as Geofabrik: continents, countries, and sub-regions down
to a single state or federal district. Your map can cover a whole country, only a
particular area you need, or several regions at once.

| 🖥 Interface | ⌨️ Command line |
|---|---|
| Navigate through the tree with `→` and `←`, search with `/` | `kmap regions` is for continents, `kmap regions europe` is for countries, `kmap regions germany` is for regions; search with `kmap regions alp` for the rest |
| Mark several regions with `space`, and they form **one seamless map** | connect ids with `+`: `kmap build austria+switzerland` |

- **The output can be split into files in several ways:** a single file if there is enough
  space on the memory card; one file per region or country; or `--parts=<n>` approximately
  equal-sized files (see `--split`).
- **The data remains constantly fresh.** Geofabrik updates its extracts once a day. All
  downloads are cached, and upon rebuilding, kmap checks the cache with the server. If a
  newer dump is detected, kmap downloads it automatically, otherwise pulls data from the
  cache. If you enlarge the map later by adding regions, only the new regions are
  downloaded.

## Installation

Download the latest build for your system from the [Releases](../../releases) page.

### Windows

Run the installer `kmap-<version>.exe`. kmap will be installed in Program Files, and its
shortcut will appear on the desktop. Windows 10 version 1803 or later is required.

The installer is unsigned, so Windows SmartScreen will show the "Windows protected your
PC" warning on the first launch. Click **More info**, then **Run anyway**. It should be
done once.

### Linux

```sh
sudo apt install ./kmap_<version>_<arch>.deb
```

Ubuntu 20.04, Debian 11, or later; Intel or ARM. WSL is also supported.

For other distros (Arch, Fedora, openSUSE, etc.), use .tar.xz. Extract the archive and put
kmap in a directory in your PATH. Only glibc, libcurl, and zlib are required.

```sh
tar -xf kmap_<version>_linux_<arch>.tar.xz
sudo install kmap*/kmap /usr/local/bin/
```

### macOS

Open the `.dmg` and drag **kmap** to the Applications folder or copy the executable file
to any folder on your `PATH`. macOS 13 or later is required; the same universal build runs
on both Intel and Apple Silicon.

The bundle is ad-hoc signed and not notarized by Apple, so Gatekeeper will block it on the
first launch: "kmap cannot be opened because Apple cannot check it for malicious
software." You just need to allow the app to run:

- On **macOS 13 and 14**, right-click **kmap** in the Applications folder, choose
  **Open**, and confirm by clicking **Open** in the dialog box.
- On **macOS 15 or later**, launch the app with a double-click, close the dialog box, then
  open **System Settings → Privacy & Security**. Scroll down to the Security section, look
  for the line stating kmap was blocked, and click **Open Anyway**.
- **From the Terminal** on any macOS version, remove the quarantine attribute:

  ```sh
  xattr -dr com.apple.quarantine /Applications/kmap.app
  ```

### First launch

kmap downloads all the necessary tools, such as Java, the mkgmap map compiler and, if
needed, pyhgtmap:

| 🖥 Interface | ⌨️ Command line |
|---|---|
| The **Toolchain** screen shows what is missing and installs it by one click | `kmap install` |
| The same screen shows the state of every tool | `kmap doctor` |

### From source

Swift 5.9 or later, and Git.

**macOS.** Xcode or its Command Line Tools only:

```sh
xcode-select --install
git clone https://github.com/kmaptool/kmap.git && cd kmap
make install    # the binary lands in .build/release/kmap, a copy in /usr/local/bin
```

**Linux, including WSL.** Install Swift by following the instructions at
[swift.org/install/linux](https://www.swift.org/install/linux/) (via swiftly or from the
archive) and the zlib development headers:

```sh
sudo apt install zlib1g-dev
git clone https://github.com/kmaptool/kmap.git && cd kmap
make install    # or make install PREFIX=~/.local
```

The Swift standard library is statically linked into the binary, Swift is not required on
the target machine.

**Windows.** Install Swift by following the instructions at
[swift.org/install/windows](https://www.swift.org/install/windows/). The page also lists
the Visual Studio components the toolchain needs. Then:

```powershell
git clone https://github.com/kmaptool/kmap.git; cd kmap
swift build -c release
```

The result is `.build\release\kmap.exe`; the toolchain installer has already put the Swift
runtime DLLs on `PATH`.

## Command line

*The following part of this guide is intended for scripting and advanced configuration.
The interface offers the exact same capabilities.* For the complete reference, run `kmap
--help`; `kmap --version` indicates the current version.

<details>
<summary><b>Every command in one list</b>. Click to unfold</summary>

```text
Help and state
  kmap                        interactive interface
  kmap --help                 full guide
  kmap --version              current version
  kmap doctor                 toolchain state
  kmap install [tool]         installs lacking tools

Regions and builds
  kmap regions [id|query]     continents, a region's contents, or a search
  kmap build <region>[+…]     builds a map
  kmap dem-cost <region>[+…]  estimates the DEM data size before building a map
  kmap fetch-dem <area>       downloads elevation tiles without building

Styles and profiles
  kmap styles                 list of styles
  kmap profiles [show|new|set|copy|rename|delete|use]
                              profiles: list and management
  kmap hideable [filter]      what --hide can remove from the map

Finished map
  kmap verify <img>           checks a built map
  kmap coverage <img>         whether tiles cover the area
  kmap typinfo <img>          what kmap sees inside an .img
  kmap typdump <typ|img>      decodes a TYP-file
  kmap typgen <palette.txt>   TYP source for the built-in palette
  kmap extract-typ <img>      pulls the TYP-file out of a map
  kmap recover <img>          recovers style of another map, according to OSM data
  kmap recover-check <a> <b>  compares two maps tag by tag
  kmap img-elements <img>     dumps elements of a map

Pipeline separate steps
  kmap split <pbf>            divides the extract into tiles
  kmap contours <hgt>         traces one elevation tile
  kmap repair-roads <in> <out>
                              fills road or trail gaps
  kmap burn-peaks             writes OSM peak heights into the elevation tiles
  kmap make-gpi <pbf> <gpi>   Custom POI file
  kmap osm-scan <pbf>         analyzes the contents of the OSM extract
  kmap tif <tif>              reads GeoTIFF tile data
  kmap tif2hgt <cell>         builds an .hgt cell from GeoTIFF
  kmap embed-assets           adds Assets/ to the source files (for developers)
```

Detailed information for each command can be found in sections below or by running `kmap
--help`.

</details>

### Flags for every command

| Flag | Description |
|---|---|
| `--json` | one JSON object per line on stdout for driving kmap from another program, see [For developers](#for-developers) |
| `--verbose` | shows details that usually goes only to the log file |

### Common functions

```text
kmap                          launches the interactive interface
kmap doctor                   reports on the toolchain
kmap install [tool]           installs missing tools; `kmap install java --download`
                              fetches kmap's own JDK even where a package manager exists
kmap regions [id|query]       no argument — the continents; a region's id opens it and
                              lists its sub-regions; any other word searches
kmap build <region-id>        builds a map; several ids joined with + become one seamless map
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
```

### Build options

A command-line build does only what it is told: anything not switched on is off.
`--profile` enables everything stored in a saved profile, while a flag overrides
one specific setting. An unknown value, such as a style that doesn't exist or a number out
of range, stops the build instead of silently replacing it with a default value.

<details>
<summary><b>Every build flag</b>. Click to unfold</summary>

| Flag | Description |
|------|--------------|
| `--profile=<name>` | starts from this profile's settings. Read-only: no build ever changes a profile |
| `--style=<id>` | style id, from `kmap styles`. Without it your device uses its built-in colors |
| `--contours`, `--no-contours` | contour lines |
| `--interval=<metres>` | contour interval |
| `--dem`, `--no-dem` | the DEM layer — shaded relief and the elevation profile |
| `--summits`, `--no-summits` | lifts the DEM at each summit to its OSM height. On with `--dem` unless switched off |
| `--sources=<list>` | elevation sources, tried in order — each fills only what the ones before it lack. Default `view1,view3`; `copernicus1,copernicus3` is recommended (global, no login); also `srtm1`, `alos1` |
| `--levels=<plan>` | how many zoom levels the map has: `standard` or `smooth` |
| `--labels=<language>` | which OSM name tag to label with: `local`, `ru` or `en` |
| `--code-page=<n>` | which alphabet the map keeps, a number or `auto` — see *Good to know* |
| `--family-id=<n>` | Garmin family id; two maps with the same id hide each other |
| `--route`, `--no-route` | routing data |
| `--repair-ends`, `--no-repair-ends` | fills gaps OSM left between road ends |
| `--repair-radius=<m>` | how far apart two ends may be and still get joined. Default 5 |
| `--index`, `--no-index` | the searchable address and POI index |
| `--word-index`, `--no-word-index` | find a street by any word of its name. `--lean-index` is the old name for `--no-word-index` |
| `--house-numbers`, `--no-house-numbers` | house numbers in the address index |
| `--sea`, `--no-sea` | generated coastlines |
| `--zoom-plan=<name>` | which zoom level each kind of feature appears at, from a plan made in the interface |
| `--descriptions[=CARRIER]` | carries OSM `description` texts into the object card: `phone`, `street`, `region`, `postcode`, `in-name`, or `off` |
| `--custom-pois`, `--no-custom-pois` | also write a `.gpi` with everything that has a description |
| `--hide=a,b,c` | leaves features off the map — benches, phones, power lines… ids from `kmap hideable` |
| `--theme=<scheme>` | which of the style's two colour schemes to pack: `all`, `day` or `night` |
| `--overlap=<units>` | let tiles paint a little past their frame — hides tile seams; needs the mkgmap patch (experimental) |
| `--land-overlap=<units>` | the same for the land layer alone. Never more than `--overlap` |
| `--split=<mode>` | how the output is cut into files: `fit`, `region`, `country` or `custom` |
| `--parts=<n>` | how many files, with `--split=custom` |
| `--max-nodes=<n>` | nodes per tile; fewer nodes means more, smaller tiles |
| `--out=<dir>` | where the finished map goes |
| `--work=<dir>` | scratch folder |
| `--keep-work` | keeps the intermediate files |
| `--heap=<GB>` | memory for the compilers, this build only |
| `--connections=<n>` | download streams, 1–16, this build only |
| `--memory=<GB>` | assumes the machine has this much memory and run fewer jobs at once |

</details>

### Looking inside a finished map

```text
kmap verify <img>             checks a built map before copying it to the device
kmap coverage <img> [--step 0.25] [--quiet]
                              whether its tiles cover the ground they claim
kmap typinfo <img>            what kmap can see inside a Garmin .img
kmap typdump <typ|img> [--polygons] [--lines] [--points] [--draw-order] [--all] [--type=0xNN]
                              decodes a TYP: colours, patterns, labels, draw order
kmap typgen <palette.txt> [--fid=N] [--out=FILE]
                              writes out the TYP source of a built-in palette
kmap extract-typ <img> [--out=DIR] [--force]
                              pulls the TYP out of a map so you can reuse or edit it
kmap recover <map.img> [--extract=FILE.pbf]… [--out=STYLE.txt] [--attach]
             [--sheet=FILE]
                              reads a third-party map against OSM data and write its look
                              back out as a style of kmap's own — its pictures on kmap's
                              numbers. --out writes the style, --attach puts it in the
                              TYP library, --sheet writes the reassignment list
kmap recover-check <original.img> <rebuilt.img> [--extract=FILE.pbf]…
                              compares two maps tag by tag — the full test of a
                              recovery, every meaning before and after
kmap img-elements <map.img> --out <dump.bin> [--ground a,b,c,d]… [--extended]
                 [--coarse] [--res=N]
                              dumps a map's drawn elements, the ground `recover` reads;
                              --coarse reads the zoomed-out levels, --res=N whatever
                              is drawn at that resolution
```

### Pipeline steps individually

<details>
<summary>For scripting and the curious: each command runs one step on its own.</summary>

```text
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
kmap fetch-dem <area> [--source view1|view3]
                              fetch elevation tiles without building anything
kmap dem-cost <region>[+<region>…] [--sources=<list>]
                              what the elevation download will weigh, per source,
                              before any build
kmap tif <file.tif> [--dump <out.f32>]
                              read a GeoTIFF elevation tile
kmap tif2hgt <cell> --dir <tiles> --out <file.hgt>
                              turn GeoTIFF tiles into one .hgt cell
kmap hideable --regenerate [--out FILE] [--points FILE]
                              rebuild the hide catalogue from the style
kmap embed-assets [--assets DIR] [--out FILE]
                              fold Assets/ back into the source (developers)
```

</details>

## Good to know

**Invisible tile seams.** Garmin maps are built from tiles, and on many devices the seams
between tiles appear as thin, light-colored lines. kmap includes a small patch for mkgmap
that allows tiles to draw slightly beyond their frames (`--overlap`, `--land-overlap`),
causing the seams to disappear. Install it once from the Toolchain screen or with `kmap
install`; without it those flags do nothing and the map is simply built in the ordinary
way.

**Line drawing order.** A Garmin device draws lines in the order they are stored in the
map. Without further processing that order is the order the data arrived in, and it
ignores how important each object is: a river can be drawn over the road it passes under,
and a driveway over the motorway it joins. The same mkgmap patch fixes this. At build time
kmap reads the road rules of the chosen style, assigns every road type a rank by its
importance and writes the roads out in ascending rank, above all other lines. This works
with any style, built-in or imported, and does not affect build time.

**Contours and relief are two different things.** *Contour lines* are the drawn elevation
lines, at the interval you choose. *The DEM layer* is what gives you shaded relief and the
elevation profile. You can have either, both, or neither; the data for both comes from one
download.

**Code page: important for non-Latin maps.** `--code-page` decides which alphabet the map
keeps: 1252 for western Europe, 1251 for Cyrillic. A wrong value silently turns local
names into Latin transliteration. kmap picks the right one for each region; `auto` leaves
that choice to it.

**Roads left short in OSM.** Mappers sometimes end a road just short of the one it joins,
and the device then won't route across the gap. With `--repair-ends` kmap closes such gaps
(up to `--repair-radius` metres) and marks the join on the map as a red dashed line
showing what has to be crossed if there was an obstacle: a kerb, a ditch, and so on. That
makes it clear the connection was added by kmap, not mapped on the ground. Routing then
runs through it like any other road.

**House numbers are search data, not labels.** Garmin devices do not paint numbers on
buildings. `--house-numbers` feeds the *address search*: on the device open *Where To? →
Addresses*, then pick the city, the street and the house number. `kmap osm-scan` shows how
many objects in the extract carry `addr:housenumber`, and `kmap verify` confirms the
finished map carries a search index.

**Descriptions on the device.** OSM objects often carry a `description` — how to find the
spring, whether the hut is open. Garmin maps have no field for it, so kmap can carry it
into the object card (`--descriptions`) and, with `--custom-pois`, write a `.gpi` file
where every such note is searchable under Custom POIs.

**Day and night.** A style has two colour schemes, day and night, and the device switches
between them on its own. Not every device does this well: some Garmin Edge models have no
dark mode, and if the map carries one, the style renders badly. In that case pack only one
scheme into the map: the **Theme** field on the build form, or `--theme=day` — the device
then always shows the day map. The reverse works too: `--theme=night` makes the map
permanently night-only.

**Interface language.** The interface is available in English and Russian — it's the first
field in Settings. This never affects the map itself: the language a road is labelled in
is decided per build, by `--labels` and the code page.

**Where things live**

```text
~/.kmap/cache     downloaded map data and elevation tiles, reused between builds
~/.kmap/styles    the rule set and style sources
~/.kmap/typ       your TYP library — imported and recovered styles
~/.kmap/logs      the full output of every build
~/kmap            finished maps, one dated folder per build
```

## Keys

| Where | Keys |
|---------|------|
| Everywhere | <kbd>↑</kbd><kbd>↓</kbd> / <kbd>j</kbd><kbd>k</kbd> move · <kbd>⏎</kbd> select · <kbd>esc</kbd> back · <kbd>^C</kbd> quit |
| Regions | <kbd>→</kbd> open · <kbd>←</kbd> back · <kbd>/</kbd> search · <kbd>space</kbd> mark for one combined map |
| Build form | <kbd>←</kbd><kbd>→</kbd> change a value · <kbd>⏎</kbd> open a list · <kbd>⏎</kbd> on Build to start |
| Styles | <kbd>n</kbd> new · <kbd>i</kbd> import · <kbd>c</kbd> copy · <kbd>r</kbd> rename · <kbd>d</kbd> delete · <kbd>m</kbd> make default |
| Library | <kbd>o</kbd> show the file in Finder / Explorer |

Keys are read by their position on the keyboard, so they keep working in a non-Latin
layout.

## System requirements

- **Windows** 10 version 1803 and later, 64-bit: x64 or ARM64
- **Linux**: Ubuntu 20.04, Debian 11, or anything newer (glibc 2.29+), x86_64 or ARM64;
  WSL works the same way
- **macOS** 13 and later, Intel or Apple Silicon
- **Java** is needed by the map compiler — `kmap install` fetches it for you, from the
  system's package manager or straight from Adoptium
- Python 3 is needed only for the optional `srtm`/`alos` elevation sources
- Internet connection for downloads; map data and elevation tiles are cached, so a rebuild
  downloads nothing unless a newer extract has appeared

## Installing a map on the device

A new map can be found in `~/kmap`, in a folder named for the build date: a single `.img`
file, or several ones if the map was split into parts. Copy them all to the `Garmin`
folder on the device or its memory card. No renaming needed. If you built a `.gpi` with
descriptions, put it to `Garmin/POI`.

## For developers

Any kmap command can be driven from another program — a shell script, Python, Go, anything
that can start a process and read its stdout. Put `--json` anywhere among the arguments:

```sh
kmap build austria --profile="GPSMap 67" --json
kmap regions alps --json
kmap doctor --json
```

**What `--json` changes.** The usual prose is not printed at all, and stderr stays silent:
everything kmap has to say goes to stdout as one JSON object per line, in the order things
happen. A failure arrives as an `error` event, not as text on stderr — the reader gets one
story, in one shape.

**The stream contract.** Every line carries three fields: `event` — the kind of event,
`seq` — a counter from 1 with no gaps (a skipped number means a lost line), `at` — a
timestamp in RFC 3339, UTC. The opening `start` line carries `schema`, the contract
version. New fields may appear in any release and a reader should ignore what it does not
know; `schema` is raised only when a field changes meaning or goes away.

| `event` | When | Fields |
|---|---|---|
| `start` | the first line | `command`, `version`, `schema` |
| `stage` | a build stage changed state | `stage`, `status`, `title`, `detail` |
| `progress` | the bar moved, or the stage said what it is doing | `overall` — fraction of the whole build, 0…1; `stage` and `fraction` — that stage's own share (absent while it has no percentage); `detail`. A successful build's last `progress` reads `overall: 1` |
| `log` | a log line | `severity` (`debug`/`info`/`warn`/`error`), `kind` (`plain`/`step`/`ok`/`output`), `text`, `stage`, `fields` — the same facts as the text, as data |
| `result` | the command's answer | `data` — see below |
| `error` | the command could not do it | `message`, `code` |
| `end` | the last line | `ok`, `code` — the same as the process exit code |

Build stages: `preflight`, `download`, `elevation`, `elevationBuild`, `split`, `compile`,
`collect`; statuses: `pending`, `running`, `done`, `skipped`, `failed`. The elevation
stages run beside the split, so two stages `running` at once is normal.

**Exit codes.** `0` — done; `1` — failed while running; `2` — bad arguments: an unknown
command, a style or profile that does not exist, a number out of range, tools not
installed; `130` — the build was interrupted. With `--json` the same code is repeated in
`end`.

**What `result.data` holds.** For `build`: `destination` (the folder), `outputs` (an array
of `{name, path, bytes}` — the files to copy to the device), `stages` (per stage: `id`,
`status`, `seconds`, `peakBytes`) and `seconds`. For `regions`: `in` (the id of the opened
region, or `null`) and `regions` with `id`, `name`, `parent`, `downloadable`,
`subRegions`, `boxes`; to walk the whole tree, open every region with `subRegions > 0`.
For `styles`: `styles` with `id`, `name`, `origin`, `familyID`. For `profiles`: `profiles`
with `id`, `name`, `current`, `choices` — the same set the flags accept. For `doctor`:
`ready` and `tools` with `id`, `ready`, `installable`, `path`. For `verify` and
`coverage`: a report per map. The easiest way to see the exact shape of any command is to
run it once with `--json`.

**Examples.** Read stdout line by line rather than waiting for the process to end, so
progress shows as it happens. Three languages, the same program:

<details>
<summary><b>Python</b> — click to unfold</summary>

```python
import json, subprocess

proc = subprocess.Popen(
    ["kmap", "build", "austria", "--profile=GPSMap 67", "--json"],
    stdout=subprocess.PIPE, text=True, encoding="utf-8")

for line in proc.stdout:
    event = json.loads(line)
    match event["event"]:
        case "progress":
            print(f"{event['overall']:.0%}  {event.get('detail', '')}")
        case "result":
            for out in event["data"]["outputs"]:
                print("built", out["path"])
        case "error":
            print("failed:", event["message"])

exit_code = proc.wait()
```

</details>

<details>
<summary><b>Go</b> — the standard library is enough</summary>

```go
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os/exec"
)

type event struct {
	Event   string  `json:"event"`
	Overall float64 `json:"overall"`
	Detail  string  `json:"detail"`
	Message string  `json:"message"`
	Data    struct {
		Outputs []struct {
			Path string `json:"path"`
		} `json:"outputs"`
	} `json:"data"`
}

func main() {
	cmd := exec.Command("kmap", "build", "austria", "--profile=GPSMap 67", "--json")
	stdout, _ := cmd.StdoutPipe()
	if err := cmd.Start(); err != nil {
		panic(err)
	}

	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 1<<20), 1<<20) // a result line can be long
	for scanner.Scan() {
		var ev event
		if err := json.Unmarshal(scanner.Bytes(), &ev); err != nil {
			continue
		}
		switch ev.Event {
		case "progress":
			fmt.Printf("%3.0f%%  %s\n", ev.Overall*100, ev.Detail)
		case "result":
			for _, out := range ev.Data.Outputs {
				fmt.Println("built", out.Path)
			}
		case "error":
			fmt.Println("failed:", ev.Message)
		}
	}

	if err := cmd.Wait(); err != nil {
		if exit, ok := err.(*exec.ExitError); ok {
			fmt.Println("exit code", exit.ExitCode())
		}
	}
}
```

</details>

<details>
<summary><b>C++</b> — with nlohmann/json; on Windows use <code>_popen</code>/<code>_pclose</code> instead of <code>popen</code>/<code>pclose</code></summary>

```cpp
#include <cstdio>
#include <iostream>
#include <string>
#include <nlohmann/json.hpp>

int main() {
    FILE* pipe = popen("kmap build austria --profile=\"GPSMap 67\" --json", "r");
    if (!pipe) return 1;

    char buffer[1 << 16];
    std::string line;
    while (fgets(buffer, sizeof buffer, pipe)) {
        line += buffer;
        if (line.back() != '\n') continue;   // a long line arrives in pieces
        auto ev = nlohmann::json::parse(line);
        line.clear();

        const std::string kind = ev["event"];
        if (kind == "progress") {
            std::cout << int(ev["overall"].get<double>() * 100) << "%  "
                      << ev.value("detail", "") << '\n';
        } else if (kind == "result") {
            for (auto& out : ev["data"]["outputs"])
                std::cout << "built " << out["path"].get<std::string>() << '\n';
        } else if (kind == "error") {
            std::cout << "failed: " << ev["message"].get<std::string>() << '\n';
        }
    }
    return pclose(pipe);   // the exit code: WEXITSTATUS on POSIX
}
```

</details>

For a one-off query, `jq` is enough:

```sh
kmap styles --json | jq -r 'select(.event == "result") | .data.styles[].id'
```

## Licence

kmap's own code is MIT — see [LICENSE](LICENSE).

There is one exception: the rule lines quoted in `Assets/hideable.txt` and
`Assets/mkgmap/redirects.txt` are mkgmap's, under GPL v2. They are quoted because a
substitution has to name the exact line it replaces.

mkgmap and pyhgtmap are not bundled: they are downloaded onto your machine from their own
repositories. The tile splitter is kmap's own. See [NOTICE.md](NOTICE.md) for more
details.

Maps you build are covered by OpenStreetMap's terms, not kmap's: the data is
[ODbL](https://www.openstreetmap.org/copyright), and so is anything made from it.
