import Foundation

/// The Java below is a patch to mkgmap: it quotes and adapts mkgmap's own source, so it is
/// GPL as mkgmap is, not MIT. See NOTICE.md.
extension Toolchain {
    /// The source edits the patch consists of: (file, anchor, replacement). A missing
    /// anchor means the release has changed and the patch must be revisited.
    static let mkgmapSourceEdits: [(String, String, String)] = {
        let clipper = "uk/me/parabola/mkgmap/general/AreaClipper.java"
        let builder = "uk/me/parabola/mkgmap/build/MapBuilder.java"
        let converter = "uk/me/parabola/mkgmap/osmstyle/StyledConverter.java"
        let relation = "uk/me/parabola/mkgmap/reader/osm/MultiPolygonRelation.java"
        let saver = "uk/me/parabola/mkgmap/reader/osm/ElementSaver.java"
        let area = "uk/me/parabola/mkgmap/build/MapArea.java"
        let splitter = "uk/me/parabola/mkgmap/build/MapSplitter.java"
        let remover = "uk/me/parabola/mkgmap/reader/osm/UnusedElementsRemoverHook.java"
        let preparer = "uk/me/parabola/imgfmt/app/trergn/LinePreparer.java"
        let heights = "uk/me/parabola/mkgmap/reader/hgt/HGTConverter.java"
        let heightFile = "uk/me/parabola/mkgmap/reader/hgt/HGTReader.java"

        let edits: [(String, String, String)] = [
            // mkgmap tries a few bases for a line's deltas and writes the whole stream for
            // each, only to compare the lengths. The lengths are counted here instead, and
            // only a stream that can be returned is written: the same bytes, sooner.
            (
                preparer,
                "\tpublic BitWriter makeShortestBitStream(int minPointsRequired) {\n"
                    + "\t\tBitWriter bsSimple = makeBitStream(minPointsRequired, xBase, yBase);",
                """
                \tpublic BitWriter makeShortestBitStream(int minPointsRequired) {
                \t\tBitWriter bsSimple = makeBitStream(minPointsRequired, xBase, yBase);
                \t\tif (bsSimple == null)
                \t\t\treturn bsSimple;
                \t\tint bestBits = bsSimple.getBitPosition();
                \t\tint xBestBase = xBase;
                \t\tint yBestBase = yBase;
                \t\tif (xBase > 0) {
                \t\t\tint notBetter = 0;
                \t\t\tint xTestBase = xBase - 1;
                \t\t\tboolean xSameSignBak = xSameSign;
                \t\t\tif (xSameSign) {
                \t\t\t\txSameSign = false;
                \t\t\t\t--xTestBase;
                \t\t\t}
                \t\t\tfor (; xTestBase >= 0; xTestBase--) {
                \t\t\t\tint bits = kmapBitLength(minPointsRequired, xTestBase, yBase);
                \t\t\t\tif (bits >= bestBits) {
                \t\t\t\t\tif (++notBetter >= 2)
                \t\t\t\t\t\tbreak;
                \t\t\t\t} else {
                \t\t\t\t\txBestBase = xTestBase;
                \t\t\t\t\tbestBits = bits;
                \t\t\t\t\txSameSignBak = false;
                \t\t\t\t}
                \t\t\t}
                \t\t\txSameSign = xSameSignBak;
                \t\t}
                \t\tif (yBase > 0) {
                \t\t\tint notBetter = 0;
                \t\t\tint yTestBase = yBase - 1;
                \t\t\tboolean ySameSignBak = ySameSign;
                \t\t\tif (ySameSign) {
                \t\t\t\tySameSign = false;
                \t\t\t\t--yTestBase;
                \t\t\t}
                \t\t\tfor (; yTestBase >= 0; yTestBase--) {
                \t\t\t\tint bits = kmapBitLength(minPointsRequired, xBestBase, yTestBase);
                \t\t\t\tif (bits >= bestBits) {
                \t\t\t\t\tif (++notBetter >= 2)
                \t\t\t\t\t\tbreak;
                \t\t\t\t} else {
                \t\t\t\t\tyBestBase = yTestBase;
                \t\t\t\t\tbestBits = bits;
                \t\t\t\t\tySameSignBak = false;
                \t\t\t\t}
                \t\t\t}
                \t\t\tySameSign = ySameSignBak;
                \t\t}
                \t\tif (xBestBase == xBase && yBestBase == yBase)
                \t\t\treturn bsSimple;
                \t\t// The sign flags now are the ones the best trial was counted with.
                \t\tBitWriter bsBest = makeBitStream(minPointsRequired, xBestBase, yBestBase);
                \t\treturn bsSimple.getLength() == bsBest.getLength() ? bsSimple : bsBest;
                \t}

                \t/** kmap: the bit position makeBitStream would end at, counted instead of written.
                \t * A width the writer refuses goes to the writer, so it fails as it would. */
                \tprivate int kmapBitLength(int minPointsRequired, int xb, int yb) {
                \t\tint xbits = base2Bits(xb) + (xSameSign ? 0 : 1);
                \t\tint ybits = base2Bits(yb) + (ySameSign ? 0 : 1);
                \t\tif (xbits >= 24 || ybits >= 24)
                \t\t\treturn makeBitStream(minPointsRequired, xb, yb).getBitPosition();
                \t\tint bits = 8 + (xSameSign ? 2 : 1) + (ySameSign ? 2 : 1) + (extTypeLine ? 1 : 0) + (extraBit ? 1 : 0);
                \t\tfor (int i = 0; i < deltas.length; i += 2) {
                \t\t\tint dx = deltas[i];
                \t\t\tint dy = deltas[i + 1];
                \t\t\tif (dx == 0 && dy == 0 && extraBit && !nodes[i / 2 + 1] && i + 2 != deltas.length)
                \t\t\t\tcontinue;
                \t\t\tbits += xSameSign ? xbits : kmapSignedBits(dx, xbits);
                \t\t\tbits += ySameSign ? ybits : kmapSignedBits(dy, ybits);
                \t\t\tif (extraBit)
                \t\t\t\tbits++;
                \t\t}
                \t\treturn bits;
                \t}

                \t/** kmap: what BitWriter.sputn writes for a value: nb bits, and nb more for every
                \t * extended-range flag put before a value that does not fit. */
                \tprivate static int kmapSignedBits(int v, int nb) {
                \t\tint mask = (1 << (nb - 1)) - 1;
                \t\tint val = Math.abs(v);
                \t\treturn val > mask ? nb * (1 + (val - 1) / mask) : nb;
                \t}

                \t/** kmap: mkgmap's own search, which writes every trial stream out; unused. */
                \tprivate BitWriter kmapWritingEachTrial(int minPointsRequired) {
                \t\tBitWriter bsSimple = makeBitStream(minPointsRequired, xBase, yBase);
                """
            ),
            // What covers what, where two lines are drawn over the same ground, is decided
            // by the order the map stores them in — and mkgmap stores them in the order
            // they happened to arrive. These edits give that order a rule: kmap reads the
            // style's own road rules and hands over a rank per type, and the ranks decide
            // the layout. A river is long, and mkgmap keeps a long line where its middle
            // falls, rarely the same piece of ground as the road it passes under, so a
            // rank cannot be honoured inside one subdivision alone: each rank is laid out
            // in a branch of its own, from the lowest up, at every zoom.
            (
                builder,
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
                    + "\t\t}"
            ),
            // Which of 2 fills covers the other is the TYP's draw order, a rule about types.
            // A wood is drawn over a settlement and a settlement over a meadow, so by
            // types alone a wood covers a meadow, and a glade drawn across a wood in OSM
            // with no hole cut for it is lost. These edits let open ground that lies on a
            // wood larger than itself take a second type, which the TYP draws over the woods.
            (
                builder,
                "\tprivate boolean orderByDecreasingArea;",
                """
                \tprivate boolean orderByDecreasingArea;
                \t/** kmap: --x-shape-lift=0x55>0x5d,0x4f>0x5e:0x59,0x50 -- each fill with the
                \t * type it takes on a larger cover, and after the colon the covers. */
                \tprivate final java.util.Map<Integer, Integer> kmapLift = new java.util.HashMap<>();
                \tprivate final java.util.Set<Integer> kmapLiftCovers = new java.util.HashSet<>();

                \t/** kmap: a fill lying on a cover larger than itself takes the type drawn over
                \t * the covers. The areas are the ones before any clipping, so a wood cut by the
                \t * tile frame is still as large as it is on the ground. A fill counts as lying
                \t * on a cover when 1/4 of its corners are inside one: a meadow whose edge only
                \t * strays under the treeline stays where it is. */
                \tprivate void kmapLiftShapes(List<MapShape> shapes) {
                \t\tif (kmapLift.isEmpty())
                \t\t\treturn;
                \t\tList<MapShape> fills = new ArrayList<>();
                \t\tList<MapShape> covers = new ArrayList<>();
                \t\tfor (MapShape s : shapes) {
                \t\t\tif (kmapLift.containsKey(s.getType()))
                \t\t\t\tfills.add(s);
                \t\t\telse if (kmapLiftCovers.contains(s.getType()))
                \t\t\t\tcovers.add(s);
                \t\t}
                \t\tif (fills.isEmpty() || covers.isEmpty())
                \t\t\treturn;
                \t\tjava.util.Map<List<Coord>, KmapRing> rings = new java.util.IdentityHashMap<>();
                \t\t// The covers by the cells they reach, 2048 map units a side.
                \t\tfinal int kmapCell = 11;
                \t\tjava.util.Map<Long, List<MapShape>> grid = new java.util.HashMap<>();
                \t\tfor (MapShape c : covers) {
                \t\t\tArea b = c.getBounds();
                \t\t\tfor (int y = b.getMinLat() >> kmapCell; y <= b.getMaxLat() >> kmapCell; y++)
                \t\t\t\tfor (int x = b.getMinLong() >> kmapCell; x <= b.getMaxLong() >> kmapCell; x++)
                \t\t\t\t\tgrid.computeIfAbsent(((long) y << 32) ^ (x & 0xffffffffL),
                \t\t\t\t\t\t\tk -> new ArrayList<>()).add(c);
                \t\t}
                \t\tfinal int kmapMostCorners = 32;
                \t\tfor (MapShape f : fills) {
                \t\t\tlong area = Math.abs(f.getFullArea());
                \t\t\tArea fb = f.getBounds();
                \t\t\tjava.util.Set<MapShape> larger = java.util.Collections.newSetFromMap(
                \t\t\t\t\tnew java.util.IdentityHashMap<>());
                \t\t\tfor (int y = fb.getMinLat() >> kmapCell; y <= fb.getMaxLat() >> kmapCell; y++)
                \t\t\t\tfor (int x = fb.getMinLong() >> kmapCell; x <= fb.getMaxLong() >> kmapCell; x++) {
                \t\t\t\t\tList<MapShape> here = grid.get(((long) y << 32) ^ (x & 0xffffffffL));
                \t\t\t\t\tif (here == null)
                \t\t\t\t\t\tcontinue;
                \t\t\t\t\tfor (MapShape c : here)
                \t\t\t\t\t\tif (Math.abs(c.getFullArea()) > area && c.getBounds().intersects(fb))
                \t\t\t\t\t\t\tlarger.add(c);
                \t\t\t\t}
                \t\t\tif (larger.isEmpty())
                \t\t\t\tcontinue;
                \t\t\tList<Coord> corners = f.getPoints();
                \t\t\tint count = corners.size() - 1;
                \t\t\tif (count < 3)
                \t\t\t\tcontinue;
                \t\t\tint step = Math.max(1, count / kmapMostCorners);
                \t\t\tint tried = 0;
                \t\t\tint inside = 0;
                \t\t\tfor (int i = 0; i < count; i += step) {
                \t\t\t\tCoord corner = corners.get(i);
                \t\t\t\ttried++;
                \t\t\t\tfor (MapShape c : larger) {
                \t\t\t\t\tif (c.getBounds().contains(corner)
                \t\t\t\t\t\t\t&& rings.computeIfAbsent(c.getPoints(), KmapRing::new).isIn(corner)) {
                \t\t\t\t\t\tinside++;
                \t\t\t\t\t\tbreak;
                \t\t\t\t\t}
                \t\t\t\t}
                \t\t\t}
                \t\t\tif (inside * 4 >= tried)
                \t\t\t\tf.setType(kmapLift.get(f.getType()));
                \t\t}
                \t}
                \t/** kmap: IsInUtil.isPointInShape with the same answer, asking only the edges that
                \t * reach the point's latitude: the others can neither cross the ray nor touch the
                \t * point. The edges are kept in bands of latitude, about 8 to a band. */
                \tprivate static final class KmapRing {
                \t\tprivate static final int EPS = 4;
                \t\tprivate final int[] lat;
                \t\tprivate final int[] lon;
                \t\tprivate int base;
                \t\tprivate int top = -1;
                \t\tprivate int shift;
                \t\tprivate int[] bandStart;
                \t\tprivate int[] bandEdges;

                \t\tKmapRing(List<Coord> points) {
                \t\t\tint n = points.size();
                \t\t\tlat = new int[n];
                \t\t\tlon = new int[n];
                \t\t\tfor (int i = 0; i < n; i++) {
                \t\t\t\tlat[i] = points.get(i).getHighPrecLat();
                \t\t\t\tlon[i] = points.get(i).getHighPrecLon();
                \t\t\t}
                \t\t\tint edges = n - 1;
                \t\t\tif (edges < 1)
                \t\t\t\treturn;
                \t\t\tint[] lo = new int[edges];
                \t\t\tint[] hi = new int[edges];
                \t\t\tbase = Integer.MAX_VALUE;
                \t\t\ttop = Integer.MIN_VALUE;
                \t\t\tfor (int i = 0; i < edges; i++) {
                \t\t\t\tlo[i] = Math.min(lat[i], lat[i + 1]) - EPS;
                \t\t\t\thi[i] = Math.max(lat[i], lat[i + 1]) + EPS;
                \t\t\t\tbase = Math.min(base, lo[i]);
                \t\t\t\ttop = Math.max(top, hi[i]);
                \t\t\t}
                \t\t\tlong span = (long) top - base + 1;
                \t\t\twhile ((span >> shift) > Math.max(1, edges / 8))
                \t\t\t\tshift++;
                \t\t\t// Long edges are filed in many bands: widen them until that stays under 4 per edge.
                \t\t\tint bands;
                \t\t\tint[] at;
                \t\t\twhile (true) {
                \t\t\t\tbands = (int) ((span - 1) >> shift) + 1;
                \t\t\t\tat = new int[bands + 1];
                \t\t\t\tlong room = bands == 1 ? Long.MAX_VALUE : 4L * edges;
                \t\t\t\tfor (int i = 0; i < edges && room >= 0; i++) {
                \t\t\t\t\tint last = (hi[i] - base) >> shift;
                \t\t\t\t\tfor (int b = (lo[i] - base) >> shift; b <= last; b++)
                \t\t\t\t\t\tat[b + 1]++;
                \t\t\t\t\troom -= last - ((lo[i] - base) >> shift) + 1;
                \t\t\t\t}
                \t\t\t\tif (room >= 0)
                \t\t\t\t\tbreak;
                \t\t\t\tshift++;
                \t\t\t}
                \t\t\tfor (int b = 0; b < bands; b++)
                \t\t\t\tat[b + 1] += at[b];
                \t\t\tbandStart = at.clone();
                \t\t\tbandEdges = new int[at[bands]];
                \t\t\tfor (int i = 0; i < edges; i++)
                \t\t\t\tfor (int b = (lo[i] - base) >> shift; b <= (hi[i] - base) >> shift; b++)
                \t\t\t\t\tbandEdges[at[b]++] = i;
                \t\t}

                \t\tboolean isIn(Coord node) {
                \t\t\tint nodeLat = node.getHighPrecLat();
                \t\t\tint nodeLon = node.getHighPrecLon();
                \t\t\tif (nodeLat < base || nodeLat > top)
                \t\t\t\treturn false;
                \t\t\tint b = (nodeLat - base) >> shift;
                \t\t\tint rhs = 0;
                \t\t\tfor (int k = bandStart[b]; k < bandStart[b + 1]; k++) {
                \t\t\t\tint r = edge(bandEdges[k], nodeLat, nodeLon);
                \t\t\t\tif (r == 3)
                \t\t\t\t\treturn false;
                \t\t\t\tif (r == 1)
                \t\t\t\t\trhs++;
                \t\t\t}
                \t\t\treturn (rhs & 1) == 1;
                \t\t}

                \t\t/** The body of isPointInShape's loop for the edge from point i to i + 1:
                \t\t * 0 nothing, 1 a crossing on the right, 2 one on the left, 3 ON. */
                \t\tprivate int edge(int i, int nodeLat, int nodeLon) {
                \t\t\tint trailLat = lat[i], trailLon = lon[i];
                \t\t\tint leadLat = lat[i + 1], leadLon = lon[i + 1];
                \t\t\tint dLat = nodeLat - leadLat;
                \t\t\tint dLon = ((nodeLon - leadLon) << 2) >> 2;
                \t\t\tif ((long) dLat * dLat + (long) dLon * dLon < EPS * EPS)
                \t\t\t\treturn 3;
                \t\t\tint minLat = Math.min(leadLat, trailLat), maxLat = Math.max(leadLat, trailLat);
                \t\t\tint minLon = Math.min(leadLon, trailLon), maxLon = Math.max(leadLon, trailLon);
                \t\t\tif (minLat - EPS > nodeLat || maxLat + EPS < nodeLat)
                \t\t\t\treturn 0;
                \t\t\tif (minLon - EPS > nodeLon && minLat < nodeLat && maxLat > nodeLat)
                \t\t\t\treturn 1;
                \t\t\tif (maxLon + EPS < nodeLon && minLat < nodeLat && maxLat > nodeLat)
                \t\t\t\treturn 2;
                \t\t\tdouble lonDif = leadLat == trailLat ? Double.POSITIVE_INFINITY
                \t\t\t\t\t: nodeLon - trailLon - (double) (nodeLat - trailLat) / (leadLat - trailLat) * (leadLon - trailLon);
                \t\t\tif (minLon - EPS <= nodeLon && maxLon + EPS >= nodeLon) {
                \t\t\t\tdouble latDif = leadLon == trailLon ? Double.POSITIVE_INFINITY
                \t\t\t\t\t\t: nodeLat - trailLat - (double) (nodeLon - trailLon) / (leadLon - trailLon) * (leadLat - trailLat);
                \t\t\t\tdouble distSqrd;
                \t\t\t\tif (Double.isInfinite(lonDif))
                \t\t\t\t\tdistSqrd = latDif * latDif;
                \t\t\t\telse if (Double.isInfinite(latDif))
                \t\t\t\t\tdistSqrd = lonDif * lonDif;
                \t\t\t\telse if (Math.abs(lonDif) < EPS || Math.abs(latDif) < EPS)
                \t\t\t\t\treturn 3;
                \t\t\t\telse
                \t\t\t\t\tdistSqrd = lonDif * lonDif * latDif * latDif / (lonDif * lonDif + latDif * latDif);
                \t\t\t\tif (distSqrd < EPS * EPS)
                \t\t\t\t\treturn 3;
                \t\t\t}
                \t\t\tif ((trailLat <= nodeLat && leadLat > nodeLat) || (trailLat > nodeLat && leadLat <= nodeLat))
                \t\t\t\treturn lonDif < 0 ? 1 : 2;
                \t\t\treturn 0;
                \t\t}
                \t}
                """
            ),
            (
                builder,
                "\t\tpathsToHGT = props.getProperty(\"dem\", null);",
                """
                \t\tString kmapLiftOption = props.getProperty("shape-lift", null);
                \t\tint kmapOn = kmapLiftOption == null ? -1 : kmapLiftOption.indexOf(':');
                \t\tif (kmapOn > 0) {
                \t\t\tfor (String kmapPair : kmapLiftOption.substring(0, kmapOn).split(",")) {
                \t\t\t\tint kmapTo = kmapPair.indexOf('>');
                \t\t\t\tif (kmapTo > 0)
                \t\t\t\t\tkmapLift.put(Integer.decode(kmapPair.substring(0, kmapTo).trim()),
                \t\t\t\t\t\t\tInteger.decode(kmapPair.substring(kmapTo + 1).trim()));
                \t\t\t}
                \t\t\tfor (String kmapOne : kmapLiftOption.substring(kmapOn + 1).split(","))
                \t\t\t\tif (!kmapOne.trim().isEmpty())
                \t\t\t\t\tkmapLiftCovers.add(Integer.decode(kmapOne.trim()));
                \t\t}
                \t\tpathsToHGT = props.getProperty("dem", null);
                """
            ),
            (
                builder,
                "\tprivate void makeMapAreas(Map map, LoadableMapDataSource src) {\n",
                "\tprivate void makeMapAreas(Map map, LoadableMapDataSource src) {\n"
                    + "\t\tkmapLiftShapes(src.getShapes());\n"
            ),
            (
                area,
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
                    + "\t}"
            ),
            (
                area,
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
                    + "\tpublic MapArea(MapDataSource src, int resolution, boolean splitPolygonsIntoArea) {"
            ),
            (
                area,
                "\t\tfor (MapLine l : src.getLines()) {\n\t\t\tif (l.getMaxResolution() < resolution)\n\t\t\t\tcontinue;",
                "\t\tfor (MapLine l : src.getLines()) {\n\t\t\tif (l.getMaxResolution() < resolution)\n\t\t\t\tcontinue;\n"
                    + "\t\t\tif (kmapBranch >= 0 && kmapRankOf(l) != kmapBranch)\n"
                    + "\t\t\t\tcontinue;"
            ),
            (
                splitter,
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
                    + "\t\tMapArea[] origArea = {ma};"
            ),
            (
                splitter,
                "\t\tif (areas == null) {\n\t\t\tlog.warn(\"initial split returned null for\", ma);\n\t\t\treturn origArea;\n\t\t}",
                "\t\tif (areas == null) {\n\t\t\tlog.warn(\"initial split returned null for\", ma);\n"
                    + "\t\t\tif (!kmapFirst.isEmpty()) {\n"
                    + "\t\t\t\tif (ma.hasData())\n"
                    + "\t\t\t\t\tkmapFirst.add(0, ma);\n"
                    + "\t\t\t\treturn kmapFirst.toArray(new MapArea[0]);\n"
                    + "\t\t\t}\n"
                    + "\t\t\treturn origArea;\n\t\t}"
            ),
            (
                splitter,
                "\t\tList<MapArea> alist = new ArrayList<>();\n\t\taddAreasToList(areas, alist, 0);",
                "\t\tList<MapArea> alist = new ArrayList<>();\n\t\taddAreasToList(areas, alist, 0);\n"
                    + "\t\t// kmap: the ranked branches follow the unranked one, lowest rank first.\n"
                    + "\t\talist.addAll(kmapFirst);"
            ),
            // The format demands an empty zoom level above the coarsest real one; mkgmap puts
            // it at coarsest-1, and capping it at 12 bits keeps it below every mapped zoom.
            (
                builder,
                "\t\t\tif (levelInfo.getBits() <= maxBits)\n\t\t\t\tmaxBits = levelInfo.getBits() - 1;",
                "\t\t\tif (levelInfo.getBits() <= maxBits)\n\t\t\t\tmaxBits = levelInfo.getBits() - 1;\n"
                    + "\t\t\t// kmap: park the mandatory empty top level far below any real zoom\n"
                    + "\t\t\tif (maxBits > 12)\n\t\t\t\tmaxBits = 12;"
            ),
            (
                clipper,
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
                """
            ),
            (
                clipper,
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
                    + "\t\tif (kmapBox == null || kmapBox.contains(shape.getBounds())){"
            ),
            (
                clipper,
                "ShapeSplitter.clipToBounds(shape.getPoints(), bbox, null)",
                "ShapeSplitter.clipToBounds(shape.getPoints(), kmapBox, null)"
            ),
            // Types that are drawn but never routed may run past the frame like a shape;
            // roads keep the exact box, since cross-tile routing joins on it to the map unit.
            (
                clipper,
                "\t\tif (bbox == null || bbox.insideBoundary(line.getBounds())){",
                "\t\tArea kmapLineBox = lineOverlapTypes.contains(line.getType()) ? shapeBbox : bbox;\n"
                    + "\t\tif (kmapLineBox == null || kmapLineBox.insideBoundary(line.getBounds())){"
            ),
            (
                clipper,
                "\t\tList<List<Coord>> list = LineClipper.clip(bbox, line.getPoints());",
                "\t\tList<List<Coord>> list = LineClipper.clip(kmapLineBox, line.getPoints());"
            ),
            (
                converter,
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
                    + "\t\tdriveOn = props.getProperty(\"drive-on\", null);"
            ),
            (
                converter,
                "\tprivate final MapCollector collector;",
                "\tprivate final MapCollector collector;\n\tprivate final int shapeClipOverlap;\n"
                    + "\tprivate final java.util.Map<Integer, Integer> shapeClipExact;\n"
                    + "\tprivate final java.util.Set<Integer> shapeClipWhole;\n"
                    + "\tprivate final java.util.Set<Integer> lineClipOverlap;"
            ),
            (
                converter,
                "\t\tthis.clipper = new AreaClipper(bbox);",
                "\t\tthis.clipper = new AreaClipper(bbox, shapeClipOverlap, shapeClipExact,\n"
                    + "\t\t\t\tshapeClipWhole, lineClipOverlap);"
            ),
            // A multipolygon never reaches AreaClipper: it is cut while the relation is
            // assembled.
            (
                relation,
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
                """
            ),
            // A relation with no member way inside the tile is dropped before clipping, so
            // only that test uses the grown frame; ring joining still works on the real tile.
            (
                relation,
                "\tprivate Area tileArea;",
                "\tprivate Area tileArea;\n"
                    + "\t/** kmap: the tile frame grown by the shape overlap, or the frame itself. */\n"
                    + "\tprivate uk.me.parabola.imgfmt.app.Area kmapClipBounds;"
            ),
            (
                relation,
                "\t\tif (w.getPoints().stream().anyMatch(tileBounds::contains))",
                "\t\tif (w.getPoints().stream().anyMatch(kmapClipBounds::contains))"
            ),
            (
                relation,
                "\t\t\tif (lineCutsBbox(w.getPoints().get(i), w.getPoints().get(i + 1))) {",
                "\t\t\tif (kmapLineCutsClip(w.getPoints().get(i), w.getPoints().get(i + 1))) {"
            ),
            (
                relation,
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
                """
            ),
            (
                saver,
                "\tpublic ElementSaver(EnhancedProperties args) {",
                "\tprivate final int shapeClipOverlap;\n\n"
                    + "\tpublic ElementSaver(EnhancedProperties args) {\n"
                    + "\t\tshapeClipOverlap = args.getProperty(\"shape-clip-overlap\", 0);"
            ),
            (
                saver,
                "return new MultiPolygonRelation(rel, wayMap, getBoundingBox());",
                "return new MultiPolygonRelation(rel, wayMap, getBoundingBox(), shapeClipOverlap);"
            ),
            // This hook drops ways with no point inside the frame before the style system
            // sees them, so the way test moves to the grown box; loose nodes keep the frame.
            (
                remover,
                "\tprivate ElementSaver saver;",
                "\tprivate ElementSaver saver;\n"
                    + "\t/** kmap: how far past its own frame a tile may paint a shape. */\n"
                    + "\tprivate int shapeClipOverlap;"
            ),
            (
                remover,
                "\t\tthis.saver = saver;",
                "\t\tthis.saver = saver;\n"
                    + "\t\tshapeClipOverlap = props.getProperty(\"shape-clip-overlap\", 0);"
            ),
            (
                remover,
                "\t\tRectangle bboxRect = new Rectangle(bbox.getMinLong(), bbox.getMinLat(), bbox.getWidth(), bbox.getHeight());",
                "\t\tfinal Area wayBox = shapeClipOverlap <= 0 ? bbox\n"
                    + "\t\t\t\t: new Area(bbox.getMinLat() - shapeClipOverlap,\n"
                    + "\t\t\t\t\t\tbbox.getMinLong() - shapeClipOverlap,\n"
                    + "\t\t\t\t\t\tbbox.getMaxLat() + shapeClipOverlap,\n"
                    + "\t\t\t\t\t\tbbox.getMaxLong() + shapeClipOverlap);\n"
                    + "\t\tRectangle bboxRect = new Rectangle(wayBox.getMinLong(), wayBox.getMinLat(),\n"
                    + "\t\t\t\twayBox.getWidth(), wayBox.getHeight());"
            ),
            (
                remover,
                "\t\t\t\tif (bbox.contains(c)) {",
                "\t\t\t\tif (wayBox.contains(c)) {"
            ),
            // A DEM point is weighed from the 16 heights around it, which mkgmap reads 1
            // call at a time into a 4 x 4 array and then walks. Nearly always all 16 are in
            // 1 file: they are read and weighed in 1 step there, the same arithmetic in the
            // same order, so the DEM comes out the same bytes.
            (
                heights,
                "\t\t\tboolean filled = fillArray(rdr, row, col, xLeft, yBottom);\n"
                    + "\t\t\tif (filled) {\n"
                    + "\t\t\t\th = (short) Math.round(bicubicInterpolation(eleArray, qx, qy));\n"
                    + "\t\t\t\tstatBicubic++;\n"
                    + "\t\t\t}\n",
                """
                \t\t\tif (xLeft > 0 && xLeft < resX - 1 && yBottom > 0 && yBottom < resY - 1) {
                \t\t\t\tdouble v = rdr.kmapBicubic(xLeft, yBottom, qx, qy);
                \t\t\t\tif (!Double.isNaN(v)) {
                \t\t\t\t\th = (short) Math.round(v);
                \t\t\t\t\tstatBicubic++;
                \t\t\t\t}
                \t\t\t} else {
                \t\t\t\tboolean filled = fillArray(rdr, row, col, xLeft, yBottom);
                \t\t\t\tif (filled) {
                \t\t\t\t\th = (short) Math.round(bicubicInterpolation(eleArray, qx, qy));
                \t\t\t\t\tstatBicubic++;
                \t\t\t\t}
                \t\t\t}

                """
            ),
            (
                heightFile,
                "\t/**\n\t * @return the resolution to use with this file, -1 is return if file is invalid\n\t */",
                """
                \t/**
                \t * kmap: the bicubic height at (xLeft + qx, yBottom + qy) from the 16 values around
                \t * it, all of which the caller knows to lie in this file. NaN if any is undefined.
                \t * The arithmetic is HGTConverter.bicubicInterpolation's, term for term.
                \t */
                \tpublic double kmapBicubic(int xLeft, int yBottom, double qx, double qy) {
                \t\tif (!read && path != null) {
                \t\t\tprepRead();
                \t\t}
                \t\tfinal ByteBuffer b = buffer;
                \t\tif (b == null)
                \t\t\treturn 0.0;
                \t\tcount += 16;
                \t\tfinal int w = numPixelsX;
                \t\t// the row of yBottom - 1; each row above it in y is w values earlier in the file
                \t\tfinal int r0 = (numPixelsY - yBottom) * w + xLeft - 1;
                \t\tfinal int r1 = r0 - w, r2 = r1 - w, r3 = r2 - w;
                \t\tdouble a0 = kmapColumn(b, r0, r1, r2, r3, 0, qy);
                \t\tdouble a1 = kmapColumn(b, r0, r1, r2, r3, 1, qy);
                \t\tdouble a2 = kmapColumn(b, r0, r1, r2, r3, 2, qy);
                \t\tdouble a3 = kmapColumn(b, r0, r1, r2, r3, 3, qy);
                \t\tif (Double.isNaN(a0) || Double.isNaN(a1) || Double.isNaN(a2) || Double.isNaN(a3))
                \t\t\treturn Double.NaN;
                \t\treturn kmapCubic(a0, a1, a2, a3, qx);
                \t}

                \tprivate static double kmapColumn(ByteBuffer b, int r0, int r1, int r2, int r3, int x, double qy) {
                \t\tshort p0 = b.getShort(2 * (r0 + x)), p1 = b.getShort(2 * (r1 + x));
                \t\tshort p2 = b.getShort(2 * (r2 + x)), p3 = b.getShort(2 * (r3 + x));
                \t\tif (p0 == UNDEF || p1 == UNDEF || p2 == UNDEF || p3 == UNDEF)
                \t\t\treturn Double.NaN;
                \t\treturn kmapCubic(p0, p1, p2, p3, qy);
                \t}

                \tprivate static double kmapCubic(double p0, double p1, double p2, double p3, double qx) {
                \t\treturn p1 + 0.5 * qx*(p2 - p0 + qx*(2.0*p0 - 5.0*p1 + 4.0*p2 - p3 + qx*(3.0*(p1 - p2) + p3 - p0)));
                \t}

                \t/**
                \t * @return the resolution to use with this file, -1 is return if file is invalid
                \t */
                """
            )
        ]

        return edits
    }()
}
