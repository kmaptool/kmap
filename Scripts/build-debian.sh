#!/bin/bash
# A .deb, built in a Docker container so it can be built from any host.
#
# The binary is linked with a static Swift standard library, so the package depends on
# nothing but the C libraries it stands on.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/build/debian"
# The oldest base Swift publishes: a binary built against an older glibc runs on newer
# ones, not the reverse. Ubuntu 20.04's glibc 2.31 is also Debian 11's, so one package
# covers both and everything since.
IMAGE="${IMAGE:-swift:6.0-focal}"

# One .deb per architecture. The host's own by default; the other is built under
# emulation and is roughly ten times slower:
#
#   Scripts/build-debian.sh                     the machine's own
#   Scripts/build-debian.sh amd64 arm64         both
ARCHES=("$@")
if [ ${#ARCHES[@]} -eq 0 ]; then
    case "$(uname -m)" in
        arm64|aarch64) ARCHES=(arm64) ;;
        *)             ARCHES=(amd64) ;;
    esac
fi

if ! docker info >/dev/null 2>&1; then
    echo "docker is not running - this needs it, and nothing else" >&2
    exit 1
fi

mkdir -p "$OUT"
for ARCH in "${ARCHES[@]}"; do
echo "=== $ARCH ==="
# The build, the layout and dpkg-deb all run inside the container.
docker run --rm --platform "linux/$ARCH" -v "$ROOT":/src -w /src "$IMAGE" bash -c '
set -euo pipefail

echo "=== building ==="
swift build -c release -Xswiftc -static-stdlib --scratch-path /tmp/kmap-deb-build-$(dpkg --print-architecture)
BINARY=/tmp/kmap-deb-build-$(dpkg --print-architecture)/release/kmap
[ -x "$BINARY" ] || { echo "no release binary"; exit 1; }

VERSION=$("$BINARY" --version | sed "s/^kmap //; s/ .*//")
ARCH=$(dpkg --print-architecture)
STAGE=/tmp/kmap-deb/kmap_${VERSION}_${ARCH}
rm -rf /tmp/kmap-deb
mkdir -p "$STAGE/DEBIAN" "$STAGE/usr/bin" "$STAGE/usr/share/doc/kmap" \
         "$STAGE/usr/share/applications"

install -m 755 "$BINARY" "$STAGE/usr/bin/kmap"

# Shared-library dependencies are read out of the binary by dpkg-shlibdeps rather than
# listed by hand: -static-stdlib links the Swift runtime in but leaves libcurl, libxml2
# and zlib outside.
command -v dpkg-shlibdeps > /dev/null 2>&1 || {
    apt-get update -qq > /dev/null
    apt-get install -y -qq dpkg-dev > /dev/null
}
# dpkg-shlibdeps insists on a source tree with debian/control; without one it prints
# nothing and the dependency list comes out empty.
mkdir -p /tmp/shlibdeps/debian
cd /tmp/shlibdeps
printf "Source: kmap\nPackage: kmap\nArchitecture: any\n" > debian/control
DEPENDS=$(dpkg-shlibdeps -O "$STAGE/usr/bin/kmap" 2>/tmp/shlibdeps/errors \
          | sed "s/^shlibs:Depends=//")
cd /src
if [ -z "$DEPENDS" ]; then
    echo "dpkg-shlibdeps could not work out what this binary needs:"
    sed "s/^/  /" /tmp/shlibdeps/errors
    exit 1
fi
echo "depends: $DEPENDS"

# Java and the rest are installed by kmap itself on demand, so they are Recommends.
cat > "$STAGE/DEBIAN/control" <<CONTROL
Package: kmap
Version: $VERSION
Section: science
Priority: optional
Architecture: $ARCH
Depends: $DEPENDS
Recommends: default-jre, unzip
Suggests: python3-venv
Maintainer: kmap
Description: OpenStreetMap to Garmin, in the terminal
 Builds Garmin maps from OpenStreetMap extracts: contour lines, a DEM elevation
 layer, and a style of your choosing. mkgmap, splitter and the elevation data are
 downloaded by kmap itself the first time they are wanted.
CONTROL

# Terminal=true: kmap draws nothing without one.
cat > "$STAGE/usr/share/applications/kmap.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=kmap
Comment=OpenStreetMap to Garmin
Exec=kmap
Icon=kmap
Terminal=true
Categories=Science;Geography;Utility;
Keywords=garmin;osm;map;gps;
DESKTOP

# Icons in the hicolor theme at every size, which is what `Icon=kmap` resolves against.
for SIZE in 16 24 32 48 64 128 256 512; do
    PNG="/src/Assets/app-icon/png/kmap-$SIZE.png"
    [ -f "$PNG" ] || continue
    DEST="$STAGE/usr/share/icons/hicolor/${SIZE}x${SIZE}/apps"
    mkdir -p "$DEST"
    install -m 644 "$PNG" "$DEST/kmap.png"
done
if [ -f /src/Assets/app-icon/kmap.svg ]; then
    mkdir -p "$STAGE/usr/share/icons/hicolor/scalable/apps"
    install -m 644 /src/Assets/app-icon/kmap.svg \
            "$STAGE/usr/share/icons/hicolor/scalable/apps/kmap.svg"
fi

cp /src/README.md "$STAGE/usr/share/doc/kmap/README.md"
gzip -9n "$STAGE/usr/share/doc/kmap/README.md"

# The oldest glibc the binary will start against, read out of the binary.
FLOOR=$(objdump -T "$STAGE/usr/bin/kmap" 2>/dev/null \
        | grep -oE "GLIBC_[0-9]+\.[0-9]+" | sort -V -u | tail -1)
echo "needs at least ${FLOOR:-an unknown glibc}"

find "$STAGE" -type d -exec chmod 755 {} +
dpkg-deb --root-owner-group --build "$STAGE" > /dev/null
mv "${STAGE}.deb" /src/build/debian/
echo "built kmap_${VERSION}_${ARCH}.deb"
dpkg-deb --info "/src/build/debian/kmap_${VERSION}_${ARCH}.deb" | sed -n "1,12p"
'
done
echo
ls -la "$OUT"
