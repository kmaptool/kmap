<div align="center">

# 🗺 kmap

**Free maps for any Garmin — handheld, watch or bike computer — built on your own computer.**

Pick a country or region. Press Build. Copy one file to the device. The map is ready.

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

## What is this?

Garmin GPS devices — handhelds, watches, bike computers — can show detailed maps.
Good maps for them usually cost money. Meanwhile [OpenStreetMap](https://www.openstreetmap.org)
is a free map of the whole world, drawn by volunteers, and often *more* detailed than
many paid maps: every trail, spring, bench and rain shelter.

**kmap turns that free map into a file your Garmin understands.** The build runs on your
own computer and takes minutes for a small region. OpenStreetMap data is refined and
updated daily — just rebuild the map whenever you need fresh data. No sign-up, and nothing
is sent anywhere.

kmap is fast: every processor core is used, downloads run in parallel and resume after a
dropped connection, everything fetched is cached, and the code itself is tuned for speed.
The second build of the same region starts in seconds, not minutes.

## Three steps

1. **Install kmap** — grab the build for your system [below](#install).
2. **Run `kmap`**, pick a country, a region or a whole continent, press **Build**. On the first run kmap offers to
   fetch the few tools it needs — one keypress, and it handles the rest.
3. **Copy the finished file** into the `Garmin` folder on the device or its memory card.
   Done.

> [!TIP]
> Not sure everything is set up? `kmap doctor` checks and tells you exactly what to do.

## What's on the map

- **Contour lines** — the thin elevation lines hikers read slopes from, at the interval
  you choose.
- **Relief shading** — the soft shadows that make mountains look like mountains, plus an
  elevation profile for your track.
- **Turn-by-turn routing** and **search** by address or place name.
- **Day and night colours**, house numbers, coastlines, points of interest.
- Labels in the local language, in English or in Russian — your choice.

Each of these is a checkbox. Leave out what your device doesn't need and the map gets
smaller and faster.

---

*From here on the guide goes from everyday tasks to fine control:* **[styles](#bring-your-own-style) · [profiles](#a-profile-for-every-device)
· [coverage](#coverage) · [install](#install) · [command line](#the-command-line)
· [good to know](#good-to-know) · [for developers](#for-developers)**

## Interface and command line

Everything in kmap can be done two ways: in the full-screen terminal interface (TUI), or
from the command line for scripts and automation. The features are the same. This guide shows
both, side by side:

| 🖥 In the interface | ⌨️ From the shell |
|---|---|
| Run `kmap` | |
| Pick a region | name it directly: `kmap build austria` |
| Choose a profile, then adjust anything for this particular map | `--profile="GPSMap 67"`, plus any flags on top |
| Press **Build** and watch the progress | the same progress, right in the terminal |

Either way the finished map lands in `~/kmap`, one dated folder per build, ready to copy
to the device.

## Bring your own style

Out of the box kmap draws maps in the familiar looks of openstreetmap.org and
OpenTopoMap — just pick one. There is a third option: **if you own a map whose
licence lets you reuse its style, kmap can make your new maps look exactly like it.**
The look of a Garmin map lives in a small file inside it (a *TYP*), and kmap can pull that
file out and work out how the map uses it. Usually nothing needs editing.

| | 🖥 In the interface | ⌨️ From the shell |
|---|---|---|
| **1 · Pull the look out of the map** | Open **Styles**, press `i`, pick the `.img` or `.typ` — kmap also scans `~/Garmin` and any plugged-in device, so a file already on a memory card turns up on its own | `kmap extract-typ my-map.img` |
| **2 · Recover its look as a style of your own** | Offered right after the import — or open the style and press `r`, *recover from its map*. What comes out is a TYP that builds: their picture for a forest on kmap's number for a forest | `kmap recover my-map.img --attach` |
| **3 · Build with it** | Pick the style on the build form | `kmap build … --style=typ:my-map` |

Step 2 is the key one. A TYP says what each drawing code looks like, but not which
code that map used for a forest or a trail. kmap works this out from the map itself, by
comparing its geometry with OpenStreetMap data for the same area — and if that data is
not downloaded yet, it names the exact region to fetch. The result is stored alongside
the imported TYP, so every later build with that style looks like the original, or very
close to it.

Styles can also be copied, renamed, edited (down to individual icon pixels) and set as
the default — all from the **Styles** screen.

## A profile for every device

A handheld with room for everything, an older watch that needs a lighter map, a bike
computer that cannot show a night theme — make a **profile** for each. A profile is a named set of build settings, the
whole build form saved under a name: 10 m contours and the full search index for one
device, 25 m and no house numbers for another.

The build form has a profile row at the top. Choosing a profile fills the form in;
anything you change after that applies to this one map only, and the profile itself stays
as you saved it.

| 🖥 In the interface | ⌨️ From the shell |
|---|---|
| **Profiles** screen: `n` new, `c` copy, `r` rename, `d` delete, `m` make current | `kmap profiles new/copy/rename/delete/use <name>` |
| Edit a profile's fields on its own form | `kmap profiles set <name> --interval=25 --no-dem …` — the same flags `kmap build` takes |
| See what a profile holds | `kmap profiles` lists them all, `kmap profiles show <name>` opens one |
| Pick one in the top row of the build form | `kmap build … --profile="GPSMap 67"` |

## Coverage

kmap uses the same region tree Geofabrik publishes: continents, countries, and
sub-regions down to a single state or federal district. Take a whole country, only the
area you need, or several regions at once.

| 🖥 In the interface | ⌨️ From the shell |
|---|---|
| Walk the tree with `→` and `←`, search with `/` | `kmap regions` — the continents, `kmap regions europe` — its countries, `kmap regions germany` — its states; anything else searches: `kmap regions alp` |
| Mark several regions with `space` — they build as **one seamless map** | join the ids with `+`: `kmap build austria+switzerland` |

- **The output can be split several ways.** One file if it fits the card; one per region
  or per country; exactly `--parts=<n>` files of roughly equal size — see `--split`.
- **The data is always fresh.** Geofabrik updates its extracts once a day. Everything
  downloaded is cached, and on a rebuild kmap checks the cache against the server: if a
  new extract is out, it fetches it; if not, it uses the cached one. Enlarge the map
  later and only the new part is downloaded.

## Install

Download the latest build for your system from the [Releases](../../releases) page.

### Windows

Run the installer — `kmap-<version>.exe`. One file for both Intel and ARM
machines, which lays down the half that matches yours, so there is nothing to choose. It
puts kmap into Program Files with a desktop shortcut; nothing else needs to be installed.
Windows 10 version 1803 or later.

The installer is not signed, so SmartScreen shows "Windows protected your PC" the first
time. Click **More info**, then **Run anyway** — that is the whole ceremony, and it happens
once.

### Linux

```sh
sudo apt install ./kmap_<version>_<arch>.deb
```

Ubuntu 20.04, Debian 11, or anything newer; Intel or ARM. Works the same under WSL —
kmap even finds a Garmin device where Windows mounted it and opens the Windows file
dialogs.

### macOS

Open the `.dmg` and drag **kmap** to Applications, or put the plain binary anywhere on
your `PATH`. macOS 13 or later, Intel or Apple Silicon — one universal build.

The bundle is signed ad-hoc and not notarized with Apple, so Gatekeeper stops it the first
time: "kmap can't be opened because Apple cannot check it for malicious software". It is
the same binary you would build from source; nothing needs to be fixed, only allowed:

- **macOS 13–14** — right-click **kmap** in Applications and choose **Open**, then **Open**
  again in the dialog.
- **macOS 15 and later** — double-click, dismiss the dialog, then open
  **System Settings → Privacy & Security**, scroll to *kmap was blocked* and click
  **Open Anyway**.
- **From a terminal**, either version — strip the quarantine mark and be done:

  ```sh
  xattr -dr com.apple.quarantine /Applications/kmap.app
  ```

After that first time macOS remembers the answer. The plain binary from `make install`
never asks: quarantine is put on downloads, not on files you compiled.

### First run

kmap fetches the tools it needs — Java, the mkgmap map compiler and, when needed,
pyhgtmap:

| 🖥 In the interface | ⌨️ From the shell |
|---|---|
| The **Toolchain** screen shows what is missing and installs it with one key | `kmap install` |
| The same screen shows the state of every tool | `kmap doctor` |

### From source

You need Swift 5.9 or newer and Git. The generated files are in the repository, so nothing
but the sources is required.

**macOS.** Xcode, or just its command line tools:

```sh
xcode-select --install
git clone https://github.com/kmaptool/kmap.git && cd kmap
make install    # the binary lands in .build/release/kmap, a copy in /usr/local/bin
```

**Linux, including WSL.** Install Swift as described on
[swift.org/install/linux](https://www.swift.org/install/linux/) — with `swiftly` or from
a tarball — and the zlib headers:

```sh
sudo apt install zlib1g-dev
git clone https://github.com/kmaptool/kmap.git && cd kmap
make install    # or make install PREFIX=~/.local
```

The Swift standard library is linked statically, so the binary runs on a machine without
Swift.

**Windows.** Install Swift as described on
[swift.org/install/windows](https://www.swift.org/install/windows/) — the page also lists
the Visual Studio components the toolchain needs. Then:

```powershell
git clone https://github.com/kmaptool/kmap.git; cd kmap
swift build -c release
```

The result is `.build\release\kmap.exe`; the toolchain installer has already put the Swift
runtime DLLs on `PATH`.

## The command line

*This half of the guide is for scripting and fine control — the interface can do all of
it too.* `kmap --help` is the full reference; `kmap --version` prints the version.

<details>
<summary><b>Every command in one list</b> — click to unfold</summary>

```text
Help and state
  kmap                        the interactive interface
  kmap --help                 the full reference
  kmap --version              the version
  kmap doctor                 the state of the toolchain
  kmap install [tool]         install missing tools

Regions and builds
  kmap regions [id|query]     the continents, a region's contents, or a search
  kmap build <region>[+…]     build a map
  kmap dem-cost <region>[+…]  weigh the elevation download before any build
  kmap fetch-dem <area>       fetch elevation tiles without building

Styles and profiles
  kmap styles                 list styles
  kmap profiles [show|new|set|copy|rename|delete|use]
                              profiles: list and manage
  kmap hideable [filter]      what --hide can leave off the map

A finished map
  kmap verify <img>           check a built map
  kmap coverage <img>         whether its tiles cover the ground they claim
  kmap typinfo <img>          what kmap sees inside an .img
  kmap typdump <typ|img>      decode a TYP
  kmap typgen <palette.txt>   the TYP source of a built-in palette
  kmap extract-typ <img>      pull the TYP out of a map
  kmap recover <img>          make a style of a third-party map's look, from OSM data
  kmap recover-check <a> <b>  compare two maps tag by tag
  kmap img-elements <img>     dump a map's drawn elements

Pipeline steps on their own
  kmap split <pbf>            cut an extract into tiles
  kmap contours <hgt>         trace one elevation tile
  kmap repair-roads <in> <out>
                              repair road ends
  kmap burn-peaks             raise summits to their OSM height
  kmap make-gpi <pbf> <gpi>   the Custom POI file
  kmap osm-scan <pbf>         count what an extract holds
  kmap tif <tif>              read a GeoTIFF tile
  kmap tif2hgt <cell>         build one .hgt cell from GeoTIFF tiles
  kmap embed-assets           fold Assets/ back into the source (developers)
```

Details for each are in the blocks below and in `kmap --help`.

</details>

### Flags for every command

| flag | what it does |
|---|---|
| `--json` | one JSON object per line on stdout — for driving kmap from another program, see [For developers](#for-developers) |
| `--verbose` | show the detail that normally goes only to the log file |

### Everyday

```text
kmap                          launch the interactive interface
kmap doctor                   report on the toolchain
kmap install [tool]           install missing tools; `kmap install java --download`
                              fetches kmap's own JDK even where a package manager exists
kmap regions [id|query]       no argument — the continents; a region's id opens it and
                              lists its sub-regions; any other word searches
kmap build <region-id>        build a map; several ids joined with + become one seamless map
kmap styles                   list available styles
kmap profiles                 list the profiles --profile can name
kmap profiles show <name>     everything one profile holds
kmap profiles new <name> [build options]
                              create a profile; the options are `kmap build`'s own
kmap profiles set <name> [build options]
                              change what a profile holds, same flags again
kmap profiles copy <name> <new-name>
kmap profiles rename <name> <new-name>
kmap profiles delete <name>   the last one stays — the build form needs one
kmap profiles use <name>      which profile the interface opens on
kmap hideable [filter]        list what --hide can leave off the map
```

### Build options

A command-line build does only what you ask for: anything not switched on stays off.
`--profile` switches on everything a saved profile holds in one go, and a flag on top of
it overrides that one setting. An unknown value — a style that doesn't exist, a number
out of range — stops the build instead of silently falling back to a default.

<details>
<summary><b>Every build flag</b> — click to unfold</summary>

| Flag | What it does |
|------|--------------|
| `--profile=<name>` | start from this profile's settings. Read-only: no build ever changes a profile |
| `--style=<id>` | style id, from `kmap styles`. Without it the device draws with its built-in colours |
| `--contours`, `--no-contours` | contour lines |
| `--interval=<metres>` | contour interval |
| `--dem`, `--no-dem` | the DEM layer — shaded relief and the elevation profile |
| `--summits`, `--no-summits` | lift the DEM at each summit to its OSM height. On with `--dem` unless switched off |
| `--sources=<list>` | elevation sources, tried in order — each fills only what the ones before it lack. Default `copernicus1,copernicus3` (recommended: global, no login); also `view1`, `view3`, `srtm1`, `alos1` |
| `--levels=standard\|smooth` | how many zoom levels the map has |
| `--labels=local\|ru\|en` | which OSM name tag to label with |
| `--code-page=<n>\|auto` | which alphabet the map keeps — see *Good to know* |
| `--family-id=<n>` | Garmin product id; two maps with the same id hide each other |
| `--route`, `--no-route` | routing data |
| `--repair-ends`, `--no-repair-ends` | close the gaps OSM left between road ends |
| `--repair-radius=<m>` | how far apart two ends may be and still get joined. Default 5 |
| `--index`, `--no-index` | the searchable address and POI index |
| `--word-index`, `--no-word-index` | find a street by any word of its name. `--lean-index` is the old name for `--no-word-index` |
| `--house-numbers`, `--no-house-numbers` | house numbers in the address index |
| `--sea`, `--no-sea` | generated coastlines |
| `--zoom-plan=<name>` | which zoom level each kind of feature appears at, from a plan made in the interface |
| `--descriptions[=CARRIER]` | carry OSM `description` texts into the object card: `phone`, `street`, `region`, `postcode`, `in-name`, or `off` |
| `--custom-pois`, `--no-custom-pois` | also write a `.gpi` with everything that has a description |
| `--hide=a,b,c` | leave features off the map — benches, phones, power lines… ids from `kmap hideable` |
| `--theme=all\|day\|night` | which of the style's two colour schemes to pack |
| `--overlap=<units>` | let tiles paint a little past their frame — hides tile seams; needs the mkgmap patch (experimental) |
| `--land-overlap=<units>` | the same for the land layer alone. Never more than `--overlap` |
| `--split=<fit\|region\|country\|custom>` | how the output is cut into files |
| `--parts=<n>` | how many files, with `--split=custom` |
| `--max-nodes=<n>` | nodes per tile; fewer nodes means more, smaller tiles |
| `--out=<dir>` | where the finished map goes |
| `--work=<dir>` | scratch folder |
| `--keep-work` | keep the intermediate files |
| `--heap=<GB>` | memory for the compilers, this build only |
| `--connections=<n>` | download streams, 1–16, this build only |
| `--memory=<GB>` | assume the machine has this much memory and run fewer jobs at once |

</details>

### Looking inside a finished map

```text
kmap verify <img>             check a built map before copying it to the device
kmap coverage <img> [--step 0.25] [--quiet]
                              whether its tiles cover the ground they claim
kmap typinfo <img>            what kmap can see inside a Garmin .img
kmap typdump <typ|img> [--polygons] [--lines] [--points] [--draw-order] [--all] [--type=0xNN]
                              decode a TYP: colours, patterns, labels, draw order
kmap typgen <palette.txt> [--fid=N] [--out=FILE]
                              write out the TYP source of a built-in palette
kmap extract-typ <img> [--out=DIR] [--force]
                              pull the TYP out of a map so you can reuse or edit it
kmap recover <map.img> [--extract=FILE.pbf]… [--out=STYLE.txt] [--attach]
             [--sheet=FILE]
                              read a third-party map against OSM data and write its look
                              back out as a style of kmap's own — its pictures on kmap's
                              numbers. --out writes the style, --attach puts it in the
                              TYP library, --sheet writes the reassignment list
kmap recover-check <original.img> <rebuilt.img> [--extract=FILE.pbf]…
                              compare two maps tag by tag — the full test of a
                              recovery, every meaning before and after
kmap img-elements <map.img> --out <dump.bin> [--ground a,b,c,d]… [--extended]
                 [--coarse] [--res=N]
                              dump a map's drawn elements, the ground `recover` reads;
                              --coarse reads the zoomed-out levels, --res=N whatever
                              is drawn at that resolution
```

### One piece of the pipeline, on its own

<details>
<summary>For scripting and for the curious — each command runs one step by itself</summary>

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

**Invisible tile seams.** Garmin maps are built from tiles, and on many devices the joins
show: hairlines of blank ground, a forest cut off mid-slope. kmap ships a small patch for
mkgmap that lets tiles paint slightly past their frame (`--overlap`, `--land-overlap`), and
the seams disappear. Install it once from the Toolchain screen or with `kmap install`;
without it those flags do nothing and the map is simply built the ordinary way.

**What covers what.** A receiver paints the lines of a map in the order the map stores
them, and that order is otherwise the order the data happened to arrive in — so a river
could be painted over the trunk road it passes under, and a driveway over the motorway it
joins. The same patch gives the order a rule: kmap reads the style's own road rules,
ranks every road type by what it carries, and the roads are laid out from the smallest up,
above everything else. It works for any style, kmap's own and a borrowed one alike, and
costs nothing at build time.

**Contours and relief are two different things.** *Contour lines* are the drawn elevation
lines, at the interval you choose. *The DEM layer* is what gives you shaded relief and the
elevation profile. You can have either, both, or neither; the data for both comes from
one download.

**Code page — worth a look for non-Latin maps.** `--code-page` decides which alphabet the
map keeps: 1252 for western Europe, 1251 for Cyrillic. A wrong value silently turns local
names into Latin transliteration. kmap picks the right one for each region; `auto` leaves
that choice to it.

**Roads OSM left an inch short.** Mappers sometimes end a road just short of the one it
joins, and the device then won't route across the gap. With `--repair-ends` kmap closes
such gaps (up to `--repair-radius` metres) and marks the join on the map as a red dashed
line saying what it crosses — a kerb, a ditch — so you can tell the connection was added
by kmap, not mapped on the ground. Routing then runs through it like any other road.

**House numbers are search data, not labels.** Garmin devices never paint numbers on
buildings — no Garmin map does that. `--house-numbers` feeds the *address search*: on the
device open *Where To? → Addresses*, pick the city and street, and the number field takes
you to the right spot. `kmap osm-scan` shows how many objects in the extract carry
`addr:housenumber`, and `kmap verify` confirms the finished map carries a search index.

**Descriptions on the device.** OSM objects often carry a `description` — how to find the
spring, whether the hut is open. Garmin maps have no field for it, so kmap can carry it
into the object card (`--descriptions`) and, with `--custom-pois`, write a `.gpi` file
where every such note is searchable under Custom POIs.

**Day and night.** A style has two colour schemes, day and night, and the device switches
between them on its own. Not every device does this well: some Garmin Edge models have
no dark mode, and if the map carries one, the style renders badly. In that case pack only
one scheme into the map: the **Theme** field on the build form, or `--theme=day` — the
device then always shows the day map. The reverse works too: `--theme=night` makes the
map night-only, for good.

**Interface language.** The interface is available in English and Russian — it's the
first field in Settings. This never affects the map itself: the language a road is
labelled in is decided per build, by `--labels` and the code page.

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
- **Linux** — Ubuntu 20.04, Debian 11, or anything newer (glibc 2.29+), x86_64 or
  ARM64; WSL works the same way
- **macOS** 13 and later, Intel or Apple Silicon
- **Java** is needed by the map compiler — `kmap install` fetches it for you, from the
  system's package manager or straight from Adoptium
- Python 3 is needed only for the optional `srtm`/`alos` elevation sources
- An internet connection for downloads; map data and elevation tiles are cached, so a
  rebuild downloads nothing unless a newer extract has appeared

## Installing a map on the device

The finished map is in `~/kmap`, in a folder named after the build date: one `.img`, or
several if the map was split into parts. Copy them all into the `Garmin` folder on the
device or its memory card. No renaming needed: the names are already unique, and the
device shows all maps side by side. If you built a `.gpi` with descriptions, it goes
into `Garmin/POI`.

## For developers

Any kmap command can be driven from another program — a shell script, Python, Go, anything that can start a process and read its stdout. Put `--json` anywhere among the arguments:

```sh
kmap build austria --profile="GPSMap 67" --json
kmap regions alps --json
kmap doctor --json
```

**What `--json` changes.** The usual prose is not printed at all, and stderr stays silent: everything kmap has to say goes to stdout as one JSON object per line, in the order things happen. A failure arrives as an `error` event, not as text on stderr — the reader gets one story, in one shape.

**The stream contract.** Every line carries three fields: `event` — the kind of event, `seq` — a counter from 1 with no gaps (a skipped number means a lost line), `at` — a timestamp in RFC 3339, UTC. The opening `start` line carries `schema`, the contract version. New fields may appear in any release and a reader should ignore what it does not know; `schema` is raised only when a field changes meaning or goes away.

| `event` | When | Fields |
|---|---|---|
| `start` | the first line | `command`, `version`, `schema` |
| `stage` | a build stage changed state | `stage`, `status`, `title`, `detail` |
| `progress` | the bar moved, or the stage said what it is doing | `overall` — fraction of the whole build, 0…1; `stage` and `fraction` — that stage's own share (absent while it has no percentage); `detail`. A successful build's last `progress` reads `overall: 1` |
| `log` | a log line | `severity` (`debug`/`info`/`warn`/`error`), `kind` (`plain`/`step`/`ok`/`output`), `text`, `stage`, `fields` — the same facts as the text, as data |
| `result` | the command's answer | `data` — see below |
| `error` | the command could not do it | `message`, `code` |
| `end` | the last line | `ok`, `code` — the same as the process exit code |

Build stages: `preflight`, `download`, `elevation`, `elevationBuild`, `split`, `compile`, `collect`; statuses: `pending`, `running`, `done`, `skipped`, `failed`. The elevation stages run beside the split, so two stages `running` at once is normal.

**Exit codes.** `0` — done; `1` — failed while running; `2` — bad arguments: an unknown command, a style or profile that does not exist, a number out of range, tools not installed; `130` — the build was interrupted. Under `--json` the same code is repeated in `end`.

**What `result.data` holds.** For `build`: `destination` (the folder), `outputs` (an array of `{name, path, bytes}` — the files to copy to the device), `stages` (per stage: `id`, `status`, `seconds`, `peakBytes`) and `seconds`. For `regions`: `in` (the id of the opened region, or `null`) and `regions` with `id`, `name`, `parent`, `downloadable`, `subRegions`, `boxes`; to walk the whole tree, open every region with `subRegions > 0`. For `styles`: `styles` with `id`, `name`, `origin`, `familyID`. For `profiles`: `profiles` with `id`, `name`, `current`, `choices` — the same set the flags accept. For `doctor`: `ready` and `tools` with `id`, `ready`, `installable`, `path`. For `verify` and `coverage`: a report per map. The easiest way to see the exact shape of any command is to run it once with `--json`.

**Examples.** Read stdout line by line rather than waiting for the process to end, so progress shows as it happens. Three languages, the same program:

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

From a shell, `jq` is enough for a one-off question:

```sh
kmap styles --json | jq -r 'select(.event == "result") | .data.styles[].id'
```

## Licence

kmap's own code is MIT — see [LICENSE](LICENSE). Use it, change it, sell it — no
permission needed.

One exception, marked where it lives: the rule lines quoted in `Assets/hideable.txt` and
`Assets/mkgmap/redirects.txt` are mkgmap's, under GPL v2. They are quoted because a
substitution has to name the exact line it replaces.

mkgmap and pyhgtmap are not bundled: kmap downloads them onto your machine from their
own projects. The tile splitter is kmap's own. [NOTICE.md](NOTICE.md) has the full details.

Maps you build are covered by OpenStreetMap's terms, not kmap's: the data is
[ODbL](https://www.openstreetmap.org/copyright), and so is anything made from it.
