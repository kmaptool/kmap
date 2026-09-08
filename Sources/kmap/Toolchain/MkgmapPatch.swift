import Foundation

/// Builds a patched copy of mkgmap.jar from the matching source release.
///
/// The patched jar sits beside the original under a name of its own and carries a marker
/// naming the patch version; it is rebuilt whenever that version changes.
extension Toolchain {
    /// The source edits the patch consists of: (file, anchor, replacement). A missing
    /// anchor means the release has changed and the patch must be revisited.
    private static let mkgmapSourceEdits: [(String, String, String)] = {
        let clipper = "uk/me/parabola/mkgmap/general/AreaClipper.java"
        let builder = "uk/me/parabola/mkgmap/build/MapBuilder.java"
        let converter = "uk/me/parabola/mkgmap/osmstyle/StyledConverter.java"
        let relation = "uk/me/parabola/mkgmap/reader/osm/MultiPolygonRelation.java"
        let saver = "uk/me/parabola/mkgmap/reader/osm/ElementSaver.java"
        let area = "uk/me/parabola/mkgmap/build/MapArea.java"
        let splitter = "uk/me/parabola/mkgmap/build/MapSplitter.java"
        let remover = "uk/me/parabola/mkgmap/reader/osm/UnusedElementsRemoverHook.java"

        let edits: [(String, String, String)] = [
            // What covers what, where two lines are drawn over the same ground, is decided
            // by the order the map stores them in — and mkgmap stores them in the order
            // they happened to arrive. These edits give that order a rule: kmap reads the
            // style's own road rules and hands over a rank per type, and the ranks decide
            // the layout. A river is long, and mkgmap keeps a long line where its middle
            // falls, rarely the same piece of ground as the road it passes under, so a
            // rank cannot be honoured inside one subdivision alone: each rank is laid out
            // in a branch of its own, from the lowest up, at every zoom.
            (builder,
             "\t\torderByDecreasingArea = props.getProperty(\"order-by-decreasing-area\", false);",
             "\t\torderByDecreasingArea = props.getProperty(\"order-by-decreasing-area\", false);\n"
             + "\t\t// kmap: --x-line-draw-order=0x0f:2,0x11f14:6 -- a type and its rank.\n"
             + "\t\t// Anything the option leaves out is rank 0, painted under all of them.\n"
             + "\t\tString kmapOrder = props.getProperty(\"line-draw-order\", null);\n"
             + "\t\tif (kmapOrder != null) {\n"
             + "\t\t\tjava.util.Map<Integer, Integer> kmapRanks = new java.util.HashMap<>();\n"
             + "\t\t\tfor (String kmapOne : kmapOrder.split(\",\")) {\n"
             + "\t\t\t\tString kmapItem = kmapOne.trim();\n"
             + "\t\t\t\tint kmapCut = kmapItem.indexOf(':');\n"
             + "\t\t\t\tif (kmapCut < 0)\n"
             + "\t\t\t\t\tcontinue;\n"
             + "\t\t\t\tkmapRanks.put(Integer.decode(kmapItem.substring(0, kmapCut).trim()),\n"
             + "\t\t\t\t\t\tInteger.decode(kmapItem.substring(kmapCut + 1).trim()));\n"
             + "\t\t\t}\n"
             + "\t\t\tMapArea.kmapLineRank = kmapRanks;\n"
             + "\t\t}"),
            (area,
             "\tprivate final boolean splitPolygonsIntoArea;",
             "\tprivate final boolean splitPolygonsIntoArea;\n"
             + "\t/** kmap: type -> drawing rank, from --x-line-draw-order. */\n"
             + "\tpublic static volatile java.util.Map<Integer, Integer> kmapLineRank = java.util.Collections.emptyMap();\n"
             + "\t/** kmap: the rank of the lines this area takes, while it is being filled. */\n"
             + "\tprivate int kmapBranch = -1;\n\n"
             + "\t/** kmap: the rank a line is drawn at -- 0 for anything the option leaves out. */\n"
             + "\tstatic int kmapRankOf(MapLine line) {\n"
             + "\t\tInteger kmapR = kmapLineRank.get(line.getType());\n"
             + "\t\treturn kmapR == null ? 0 : kmapR;\n"
             + "\t}"),
            (area,
             "\tpublic MapArea(MapDataSource src, int resolution, boolean splitPolygonsIntoArea) {",
             "\t/** kmap: the part of a source drawn at one rank. The points and the shapes\n"
             + "\t * travel with rank 0, the branch laid out first, so nothing is counted twice. */\n"
             + "\tpublic MapArea(MapDataSource src, int resolution, boolean splitPolygonsIntoArea,\n"
             + "\t\t\tint kmapBranch) {\n"
             + "\t\tthis.areaResolution = 0;\n"
             + "\t\tthis.bounds = src.getBounds();\n"
             + "\t\tthis.splitPolygonsIntoArea = splitPolygonsIntoArea;\n"
             + "\t\tthis.kmapBranch = kmapBranch;\n"
             + "\t\tif (kmapBranch == 0) {\n"
             + "\t\t\tfor (MapPoint p : src.getPoints()) {\n"
             + "\t\t\t\tif (p.getMaxResolution() < resolution)\n"
             + "\t\t\t\t\tcontinue;\n"
             + "\t\t\t\tif (bounds.contains(p.getLocation()))\n"
             + "\t\t\t\t\taddPoint(p);\n"
             + "\t\t\t}\n"
             + "\t\t}\n"
             + "\t\taddLines(src, resolution);\n"
             + "\t\tif (kmapBranch == 0)\n"
             + "\t\t\taddPolygons(src, resolution);\n"
             + "\t\tthis.areaResolution = resolution;\n"
             + "\t}\n\n"
             + "\tpublic MapArea(MapDataSource src, int resolution, boolean splitPolygonsIntoArea) {"),
            (area,
             "\t\tfor (MapLine l : src.getLines()) {\n\t\t\tif (l.getMaxResolution() < resolution)\n\t\t\t\tcontinue;",
             "\t\tfor (MapLine l : src.getLines()) {\n\t\t\tif (l.getMaxResolution() < resolution)\n\t\t\t\tcontinue;\n"
             + "\t\t\tif (kmapBranch >= 0 && kmapRankOf(l) != kmapBranch)\n"
             + "\t\t\t\tcontinue;"),
            (splitter,
             "\t\tMapArea ma = initialArea(mapSource, orderByDecreasingArea);\n\t\tMapArea[] origArea = {ma};",
             "\t\t// kmap: one branch of subdivisions per rank, laid out from the lowest up.\n"
             + "\t\t// The receiver paints subdivision by subdivision, so a river -- rank 0,\n"
             + "\t\t// like everything the option does not name -- is painted before any road,\n"
             + "\t\t// and a street before the trunk it joins, wherever on the map they meet.\n"
             + "\t\t// Each branch is split by the same rules, so every size limit still holds.\n"
             + "\t\tint kmapTop = 0;\n"
             + "\t\tfor (int kmapR : MapArea.kmapLineRank.values())\n"
             + "\t\t\tkmapTop = Math.max(kmapTop, kmapR);\n"
             + "\t\tList<MapArea> kmapFirst = new ArrayList<>();\n"
             + "\t\tfor (int kmapR = 1; kmapR <= kmapTop; kmapR++) {\n"
             + "\t\t\tMapArea kmapUp = new MapArea(mapSource, zoom.getResolution(),\n"
             + "\t\t\t\t\torderByDecreasingArea, kmapR);\n"
             + "\t\t\tif (!kmapUp.hasData())\n"
             + "\t\t\t\tcontinue;\n"
             + "\t\t\tMapArea[] kmapAreas = splitMaxSize(kmapUp);\n"
             + "\t\t\tif (kmapAreas == null)\n"
             + "\t\t\t\tkmapFirst.add(kmapUp);\n"
             + "\t\t\telse\n"
             + "\t\t\t\taddAreasToList(kmapAreas, kmapFirst, 0);\n"
             + "\t\t}\n"
             + "\t\tMapArea ma = kmapTop == 0 ? initialArea(mapSource, orderByDecreasingArea)\n"
             + "\t\t\t\t: new MapArea(mapSource, zoom.getResolution(), orderByDecreasingArea, 0);\n"
             + "\t\tMapArea[] origArea = {ma};"),
            (splitter,
             "\t\tif (areas == null) {\n\t\t\tlog.warn(\"initial split returned null for\", ma);\n\t\t\treturn origArea;\n\t\t}",
             "\t\tif (areas == null) {\n\t\t\tlog.warn(\"initial split returned null for\", ma);\n"
             + "\t\t\tif (!kmapFirst.isEmpty()) {\n"
             + "\t\t\t\tif (ma.hasData())\n"
             + "\t\t\t\t\tkmapFirst.add(0, ma);\n"
             + "\t\t\t\treturn kmapFirst.toArray(new MapArea[0]);\n"
             + "\t\t\t}\n"
             + "\t\t\treturn origArea;\n\t\t}"),
            (splitter,
             "\t\tList<MapArea> alist = new ArrayList<>();\n\t\taddAreasToList(areas, alist, 0);",
             "\t\tList<MapArea> alist = new ArrayList<>();\n\t\taddAreasToList(areas, alist, 0);\n"
             + "\t\t// kmap: the ranked branches follow the unranked one, lowest rank first.\n"
             + "\t\talist.addAll(kmapFirst);"),
            // The format demands an empty zoom level above the coarsest real one; mkgmap puts
            // it at coarsest-1, and capping it at 12 bits keeps it below every mapped zoom.
            (builder,
             "\t\t\tif (levelInfo.getBits() <= maxBits)\n\t\t\t\tmaxBits = levelInfo.getBits() - 1;",
             "\t\t\tif (levelInfo.getBits() <= maxBits)\n\t\t\t\tmaxBits = levelInfo.getBits() - 1;\n"
             + "\t\t\t// kmap: park the mandatory empty top level far below any real zoom\n"
             + "\t\t\tif (maxBits > 12)\n\t\t\t\tmaxBits = 12;"),
            (clipper,
             "\tprivate final Area bbox;\n\n\tpublic AreaClipper(Area bbox) {\n\t\tthis.bbox = bbox;\n\t}",
             """
             \tprivate final Area bbox;
             \tprivate final Area shapeBbox;
             \tprivate final java.util.Map<Integer, Integer> exactTypes;
             \tprivate final java.util.Map<Integer, Area> narrowBoxes = new java.util.HashMap<>();
             \tprivate final java.util.Set<Integer> wholeTypes;
             \tprivate final java.util.Set<Integer> lineOverlapTypes;

             \tpublic AreaClipper(Area bbox) {
             \t\tthis(bbox, 0, java.util.Collections.emptyMap(), java.util.Collections.emptySet(),
             \t\t\t\tjava.util.Collections.emptySet());
             \t}

             \t/** kmap: shapes clip to a box grown by shapeOverlap and lines to the tile
             \t * exactly, except the drawn-but-not-routed ones named in lineOverlap. */
             \tpublic AreaClipper(Area bbox, int shapeOverlap, java.util.Map<Integer, Integer> exact,
             \t\t\tjava.util.Set<Integer> whole, java.util.Set<Integer> lineOverlap) {
             \t\tthis.bbox = bbox;
             \t\tthis.lineOverlapTypes = lineOverlap == null ? java.util.Collections.emptySet() : lineOverlap;
             \t\tthis.exactTypes = exact == null ? java.util.Collections.emptyMap() : exact;
             \t\tthis.wholeTypes = whole == null ? java.util.Collections.emptySet() : whole;
             \t\tif (bbox == null || shapeOverlap <= 0) {
             \t\t\tthis.shapeBbox = bbox;
             \t\t} else {
             \t\t\tthis.shapeBbox = new Area(bbox.getMinLat() - shapeOverlap,
             \t\t\t\t\tbbox.getMinLong() - shapeOverlap,
             \t\t\t\t\tbbox.getMaxLat() + shapeOverlap,
             \t\t\t\t\tbbox.getMaxLong() + shapeOverlap);
             \t\t}
             \t}

             \t/** kmap: the tile grown by one type's OWN margin. The land layer wants a few
             \t * hundred units -- enough that rounding at the coarse levels cannot pull its
             \t * edge inside the frame, and far short of the shape overlap, which would lay
             \t * opaque ground kilometres into the neighbour. Cached: asked once per shape. */
             \tprivate Area kmapNarrow(int margin) {
             \t\tif (bbox == null || margin <= 0)
             \t\t\treturn bbox;
             \t\treturn narrowBoxes.computeIfAbsent(margin, kmapM -> new Area(
             \t\t\t\tbbox.getMinLat() - kmapM, bbox.getMinLong() - kmapM,
             \t\t\t\tbbox.getMaxLat() + kmapM, bbox.getMaxLong() + kmapM));
             \t}
             """),
            (clipper,
             "\t\tif (bbox == null || bbox.contains(shape.getBounds())){",
             "\t\tint kmapT = shape.getType();\n"
             + "\t\t// kmap: a hatch is handed over whole -- every tile that holds any of it\n"
             + "\t\t// gets the same uncut shape, so the copies share a bounding box and the\n"
             + "\t\t// receiver gives them the same pattern phase. Giving it to one tile only,\n"
             + "\t\t// by centre, was tried and lost the parts outside that tile: the device\n"
             + "\t\t// does clip a tile to its own frame when it becomes the active one.\n"
             + "\t\tArea kmapBox = wholeTypes.contains(kmapT) ? null\n"
             + "\t\t\t\t: exactTypes.containsKey(kmapT)\n"
             + "\t\t\t\t\t? kmapNarrow(exactTypes.get(kmapT)) : shapeBbox;\n"
             + "\t\tif (kmapBox == null || kmapBox.contains(shape.getBounds())){"),
            (clipper,
             "ShapeSplitter.clipToBounds(shape.getPoints(), bbox, null)",
             "ShapeSplitter.clipToBounds(shape.getPoints(), kmapBox, null)"),
            // Types that are drawn but never routed may run past the frame like a shape;
            // roads keep the exact box, since cross-tile routing joins on it to the map unit.
            (clipper,
             "\t\tif (bbox == null || bbox.insideBoundary(line.getBounds())){",
             "\t\tArea kmapLineBox = lineOverlapTypes.contains(line.getType()) ? shapeBbox : bbox;\n"
             + "\t\tif (kmapLineBox == null || kmapLineBox.insideBoundary(line.getBounds())){"),
            (clipper,
             "\t\tList<List<Coord>> list = LineClipper.clip(bbox, line.getPoints());",
             "\t\tList<List<Coord>> list = LineClipper.clip(kmapLineBox, line.getPoints());"),
            (converter,
             "\t\tdriveOn = props.getProperty(\"drive-on\", null);",
             "\t\tshapeClipOverlap = props.getProperty(\"shape-clip-overlap\", 0);\n"
             + "\t\t// kmap: each entry is a type, optionally with its own margin after a\n"
             + "\t\t// colon -- 0x27:256 means the land clips 256 units past the frame.\n"
             + "\t\t// A bare type means the exact frame, as before.\n"
             + "\t\tshapeClipExact = new java.util.HashMap<>();\n"
             + "\t\tString kmapList = props.getProperty(\"shape-clip-exact\", null);\n"
             + "\t\tif (kmapList != null)\n"
             + "\t\t\tfor (String kmapOne : kmapList.split(\",\")) {\n"
             + "\t\t\t\tString kmapItem = kmapOne.trim();\n"
             + "\t\t\t\tif (kmapItem.isEmpty())\n"
             + "\t\t\t\t\tcontinue;\n"
             + "\t\t\t\tint kmapCut = kmapItem.indexOf(':');\n"
             + "\t\t\t\tString kmapKey = kmapCut < 0 ? kmapItem\n"
             + "\t\t\t\t\t\t: kmapItem.substring(0, kmapCut).trim();\n"
             + "\t\t\t\tint kmapMargin = kmapCut < 0 ? 0\n"
             + "\t\t\t\t\t\t: Integer.decode(kmapItem.substring(kmapCut + 1).trim());\n"
             + "\t\t\t\tshapeClipExact.put(Integer.decode(kmapKey), kmapMargin);\n"
             + "\t\t\t}\n"
             + "\t\tshapeClipWhole = new java.util.HashSet<>();\n"
             + "\t\tString kmapW = props.getProperty(\"shape-clip-whole\", null);\n"
             + "\t\tif (kmapW != null)\n"
             + "\t\t\tfor (String kmapTwo : kmapW.split(\",\"))\n"
             + "\t\t\t\tif (!kmapTwo.trim().isEmpty())\n"
             + "\t\t\t\t\tshapeClipWhole.add(Integer.decode(kmapTwo.trim()));\n"
             + "\t\tlineClipOverlap = new java.util.HashSet<>();\n"
             + "\t\tString kmapL = props.getProperty(\"line-clip-overlap\", null);\n"
             + "\t\tif (kmapL != null)\n"
             + "\t\t\tfor (String kmapThree : kmapL.split(\",\"))\n"
             + "\t\t\t\tif (!kmapThree.trim().isEmpty())\n"
             + "\t\t\t\t\tlineClipOverlap.add(Integer.decode(kmapThree.trim()));\n"
             + "\t\tdriveOn = props.getProperty(\"drive-on\", null);"),
            (converter,
             "\tprivate final MapCollector collector;",
             "\tprivate final MapCollector collector;\n\tprivate final int shapeClipOverlap;\n"
             + "\tprivate final java.util.Map<Integer, Integer> shapeClipExact;\n"
             + "\tprivate final java.util.Set<Integer> shapeClipWhole;\n"
             + "\tprivate final java.util.Set<Integer> lineClipOverlap;"),
            (converter,
             "\t\tthis.clipper = new AreaClipper(bbox);",
             "\t\tthis.clipper = new AreaClipper(bbox, shapeClipOverlap, shapeClipExact,\n"
             + "\t\t\t\tshapeClipWhole, lineClipOverlap);"),
            // A multipolygon never reaches AreaClipper: it is cut while the relation is
            // assembled.
            (relation,
             "\t\tthis.tileWayMap = wayMap;\n\t\tthis.tileBounds = bbox;\n"
             + "\t\t// create an Area for the bbox to clip the polygons\n"
             + "\t\ttileArea = Java2DConverter.createBoundsArea(tileBounds); ",
             """
             \t\tthis(other, wayMap, bbox, 0);
             \t}

             \t/** kmap: the CLIPPING area is grown; tileBounds stays the real tile. */
             \tpublic MultiPolygonRelation(Relation other, Map<Long, Way> wayMap,
             \t\t\tuk.me.parabola.imgfmt.app.Area bbox, int shapeOverlap) {
             \t\tthis.tileWayMap = wayMap;
             \t\tthis.tileBounds = bbox;
             \t\tuk.me.parabola.imgfmt.app.Area clipBounds = bbox;
             \t\tif (bbox != null && shapeOverlap > 0) {
             \t\t\tclipBounds = new uk.me.parabola.imgfmt.app.Area(bbox.getMinLat() - shapeOverlap,
             \t\t\t\t\tbbox.getMinLong() - shapeOverlap,
             \t\t\t\t\tbbox.getMaxLat() + shapeOverlap,
             \t\t\t\t\tbbox.getMaxLong() + shapeOverlap);
             \t\t}
             \t\tkmapClipBounds = clipBounds;
             \t\ttileArea = Java2DConverter.createBoundsArea(clipBounds); 
             """),
            // A relation with no member way inside the tile is dropped before clipping, so
            // only that test uses the grown frame; ring joining still works on the real tile.
            (relation,
             "\tprivate Area tileArea;",
             "\tprivate Area tileArea;\n"
             + "\t/** kmap: the tile frame grown by the shape overlap, or the frame itself. */\n"
             + "\tprivate uk.me.parabola.imgfmt.app.Area kmapClipBounds;"),
            (relation,
             "\t\tif (w.getPoints().stream().anyMatch(tileBounds::contains))",
             "\t\tif (w.getPoints().stream().anyMatch(kmapClipBounds::contains))"),
            (relation,
             "\t\t\tif (lineCutsBbox(w.getPoints().get(i), w.getPoints().get(i + 1))) {",
             "\t\t\tif (kmapLineCutsClip(w.getPoints().get(i), w.getPoints().get(i + 1))) {"),
            (relation,
             "\tprivate boolean lineCutsBbox(Coord p1, Coord p2) {",
             """
             \t/** kmap: lineCutsBbox against the grown frame, for the outside test alone. */
             \tprivate boolean kmapLineCutsClip(Coord p1, Coord p2) {
             \t\tuk.me.parabola.imgfmt.app.Area b = kmapClipBounds;
             \t\tCoord nw = new Coord(b.getMaxLat(), b.getMinLong());
             \t\tCoord sw = new Coord(b.getMinLat(), b.getMinLong());
             \t\tCoord se = new Coord(b.getMinLat(), b.getMaxLong());
             \t\tCoord ne = new Coord(b.getMaxLat(), b.getMaxLong());
             \t\treturn linesCutEachOther(nw, sw, p1, p2)
             \t\t\t\t|| linesCutEachOther(sw, se, p1, p2)
             \t\t\t\t|| linesCutEachOther(se, ne, p1, p2)
             \t\t\t\t|| linesCutEachOther(ne, nw, p1, p2);
             \t}

             \tprivate boolean lineCutsBbox(Coord p1, Coord p2) {
             """),
            (saver,
             "\tpublic ElementSaver(EnhancedProperties args) {",
             "\tprivate final int shapeClipOverlap;\n\n"
             + "\tpublic ElementSaver(EnhancedProperties args) {\n"
             + "\t\tshapeClipOverlap = args.getProperty(\"shape-clip-overlap\", 0);"),
            (saver,
             "return new MultiPolygonRelation(rel, wayMap, getBoundingBox());",
             "return new MultiPolygonRelation(rel, wayMap, getBoundingBox(), shapeClipOverlap);"),
            // This hook drops ways with no point inside the frame before the style system
            // sees them, so the way test moves to the grown box; loose nodes keep the frame.
            (remover,
             "\tprivate ElementSaver saver;",
             "\tprivate ElementSaver saver;\n"
             + "\t/** kmap: how far past its own frame a tile may paint a shape. */\n"
             + "\tprivate int shapeClipOverlap;"),
            (remover,
             "\t\tthis.saver = saver;",
             "\t\tthis.saver = saver;\n"
             + "\t\tshapeClipOverlap = props.getProperty(\"shape-clip-overlap\", 0);"),
            (remover,
             "\t\tRectangle bboxRect = new Rectangle(bbox.getMinLong(), bbox.getMinLat(), bbox.getWidth(), bbox.getHeight());",
             "\t\tfinal Area wayBox = shapeClipOverlap <= 0 ? bbox\n"
             + "\t\t\t\t: new Area(bbox.getMinLat() - shapeClipOverlap,\n"
             + "\t\t\t\t\t\tbbox.getMinLong() - shapeClipOverlap,\n"
             + "\t\t\t\t\t\tbbox.getMaxLat() + shapeClipOverlap,\n"
             + "\t\t\t\t\t\tbbox.getMaxLong() + shapeClipOverlap);\n"
             + "\t\tRectangle bboxRect = new Rectangle(wayBox.getMinLong(), wayBox.getMinLat(),\n"
             + "\t\t\t\twayBox.getWidth(), wayBox.getHeight());"),
            (remover,
             "\t\t\t\tif (bbox.contains(c)) {",
             "\t\t\t\tif (wayBox.contains(c)) {")
        ]

        return edits
    }()

    func patchMkgmap(log: Log, runner: ProcessRunner,
                     progress: InstallProgress? = nil) async throws {
        let stock = try await stockMkgmap(log: log, runner: runner, progress: progress)
        progress?.step(t("building the patched mkgmap"))
        // The patch is compiled here, so it takes a JDK — not whichever Java runs mkgmap.
        guard let java = findJavaKit(), java.isKit else {
            throw InstallError.unsupported(
                findJava() == nil
                ? t("Java is needed to build the patch")
                : t("this Java is a runtime — install a full JDK, or build without the patch"))
        }
        let javac = ToolLocations.companion("javac", of: java.path)
        let jarTool = ToolLocations.companion("jar", of: java.path)

        // The source archive has to match the jar, or the compiled classes will not fit it.
        guard let archive = Archive.current else {
            throw InstallError.unsupported(Archive.missingNote())
        }
        let revision = try mkgmapRevision(of: stock, archive: archive)
        log.step("patching mkgmap r\(revision)")

        let staging = Paths.tools.appendingPathComponent("mkgmap-patch-\(UUID().uuidString.prefix(8))")
        Paths.ensure(staging)
        defer { FileTools.removeIfPresent(staging) }

        let src = try await fetchMkgmapSource(revision: revision, into: staging,
                                              archive: archive, log: log, runner: runner)
        try applyPatchEdits(under: src, revision: revision, log: log)

        let classes = staging.appendingPathComponent("classes")
        Paths.ensure(classes)
        var classpath = [stock.nativePath]
        let libs = stock.deletingLastPathComponent().appendingPathComponent("lib")
        if let jars = try? FileManager.default.contentsOfDirectory(at: libs, includingPropertiesForKeys: nil) {
            classpath += jars.filter { $0.pathExtension == "jar" }.map(\.nativePath)
        }
        // `javac` and `jar` are JVMs too and take JVM options only through `-J`, so the
        // options this machine's Java needs to start are passed to them as well.
        var arguments = java.toolOptions
            + ["-nowarn", "-classpath",
               classpath.joined(separator: ToolLocations.classpathSeparator()),
               "-d", classes.nativePath]
        // Compile exactly the files the edits touched: a hand-kept list would ship stock
        // bytecode for any newly patched file.
        arguments += Set(Toolchain.mkgmapSourceEdits.map(\.0)).sorted()
            .map { src.appendingPathComponent($0).nativePath }
        log.step("compiling")
        try await runner.run(javac, arguments) { line in log.output(line) }

        let home = Toolchain.patchedMkgmapURL.deletingLastPathComponent()
        Paths.ensure(home)
        FileTools.removeIfPresent(Toolchain.patchedMkgmapURL)
        try FileManager.default.copyItem(at: stock, to: Toolchain.patchedMkgmapURL)

        // The mkgmap manifest names its dependencies with a relative Class-Path, so the jar
        // runs only with lib/ beside it, and the patched copy lands in another directory.
        let stockLibs = stock.deletingLastPathComponent().appendingPathComponent("lib")
        let ourLibs = home.appendingPathComponent("lib")
        if FileTools.exists(stockLibs), stockLibs != ourLibs {
            FileTools.removeIfPresent(ourLibs)
            try FileManager.default.copyItem(at: stockLibs, to: ourLibs)
            log.append("copied lib/ beside the patched jar")
        }

        let marker = classes.appendingPathComponent(Toolchain.patchMarker)
        try ("built-from: r\(revision)\npatch-version: \(Toolchain.patchVersion)\n"
             + "option: --x-shape-clip-overlap\n"
             + "option: --x-line-draw-order\n")
            .write(to: marker, atomically: true, encoding: .utf8)
        try await runner.run(jarTool,
                             java.toolOptions
                             + ["uf", Toolchain.patchedMkgmapURL.nativePath,
                                "-C", classes.nativePath, "uk",
                                "-C", classes.nativePath, Toolchain.patchMarker]) { line in log.output(line) }

        guard Toolchain.isPatched(Toolchain.patchedMkgmapURL) else {
            FileTools.removeIfPresent(Toolchain.patchedMkgmapURL)
            throw InstallError.failed("the patched jar came out without its marker")
        }
        log.ok("patched mkgmap at \(Paths.display(Toolchain.patchedMkgmapURL))")
    }

    /// An unpatched jar to build from; a stock release is fetched when none is installed.
    private func stockMkgmap(log: Log, runner: ProcessRunner,
                             progress: InstallProgress?) async throws -> URL {
        if mkgmapCandidates().first(where: { FileTools.exists($0) && Toolchain.patchVersion(of: $0) == 0 }) == nil {
            log.step("fetching a stock mkgmap to patch")
            try await installMkgmap(log: log, runner: runner, progress: progress)
            invalidate()
        }
        guard let stock = mkgmapCandidates().first(where: {
            FileTools.exists($0) && Toolchain.patchVersion(of: $0) == 0
        }) else {
            throw InstallError.unsupported("no unpatched mkgmap.jar to build from")
        }
        return stock
    }

    /// The revision the jar was built from, read from its own version file.
    private func mkgmapRevision(of stock: URL, archive: Archive) throws -> String {
        let version = archive.read("mkgmap-version.properties", from: stock)
        guard let listing = ProcessRunner.capture(version.executable, version.arguments),
              let revision = listing.allMatches("svn.version: ([0-9]+)").first?
                .allMatches("[0-9]+").first else {
            throw InstallError.failed("could not read the mkgmap revision from \(stock.lastPathComponent)")
        }
        return revision
    }

    /// Downloads and unpacks the source release matching the jar.
    ///
    /// - Returns: the unpacked `src` directory.
    private func fetchMkgmapSource(revision: String, into staging: URL, archive: Archive,
                                   log: Log, runner: ProcessRunner) async throws -> URL {
        let file = "mkgmap-r\(revision)-src.zip"
        guard let url = URL(string: "https://www.mkgmap.org.uk/download/" + file) else {
            throw InstallError.failed("bad source URL for \(file)")
        }
        let zip = staging.appendingPathComponent(file)
        try await Downloader(log: log).download(url: url, to: zip, connections: 4)
        let unpack = archive.unpack(zip, into: staging)
        try await runner.run(unpack.executable, unpack.arguments) { _ in }

        guard let root = (try? FileManager.default.contentsOfDirectory(
            at: staging, includingPropertiesForKeys: nil))?
            .first(where: { $0.lastPathComponent.hasPrefix("mkgmap-r") && !$0.pathExtension.contains("zip") }) else {
            throw InstallError.failed("the source archive did not unpack as expected")
        }
        return root.appendingPathComponent("src")
    }

    /// Applies every edit of `mkgmapSourceEdits`, exact-anchor only.
    private func applyPatchEdits(under src: URL, revision: String, log: Log) throws {
        let edits = Toolchain.mkgmapSourceEdits
        for (relative, anchor, replacement) in edits {
            let file = src.appendingPathComponent(relative)
            guard var text = try? String(contentsOf: file, encoding: .utf8) else {
                throw InstallError.failed("missing source file \(relative)")
            }
            guard let found = text.range(of: anchor) else {
                throw InstallError.failed(
                    "r\(revision) has changed \(relative) — the patch needs revisiting")
            }
            text.replaceSubrange(found, with: replacement)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        log.append("\(edits.count) edit(s) applied to \(Set(edits.map(\.0)).count) file(s)")
    }
}
