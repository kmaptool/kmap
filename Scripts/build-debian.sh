#!/bin/bash
# A .deb of kmap, built on the Debian or Ubuntu it is for: a real machine, a virtual one
# or a container. The machine's own architecture; the other one is built the same way on
# a machine of that architecture, and the two builds sit side by side in one checkout.
#
# The binary is linked with a static Swift standard library, so the package depends on
# nothing but the C libraries it stands on. Build on the oldest base you mean to support:
# a binary built against an older glibc runs on newer ones, not the reverse. Ubuntu 20.04
# (glibc 2.31, also Debian 11's) covers everything since.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/build/debian"

# ---------------------------------------------------------------- the machine

if [ "$(uname -s)" != "Linux" ] || ! command -v dpkg-deb >/dev/null 2>&1; then
    echo "this builds a Debian package, and needs Debian or Ubuntu to build it on" >&2
    exit 1
fi
if ! command -v swift >/dev/null 2>&1; then
    echo "missing:" >&2
    echo "  swift (swift.org/install/linux)" >&2
    exit 1
fi
# The packaging tools come from apt. As root they are installed outright; otherwise the
# script asks first, and does not touch the machine at all without a terminal to ask on
# or with SKIP_APT=1.
PACKAGES=()
command -v dpkg-shlibdeps >/dev/null 2>&1 || PACKAGES+=(dpkg-dev)
command -v objdump >/dev/null 2>&1 || PACKAGES+=(binutils)
if [ ${#PACKAGES[@]} -gt 0 ]; then
    BY_HAND="apt-get install ${PACKAGES[*]}"
    SUDO=""
    if [ "$(id -u)" -ne 0 ]; then
        SUDO="sudo"
        BY_HAND="sudo $BY_HAND"
    fi
    if [ "${SKIP_APT:-}" = "1" ]; then
        echo "missing ${PACKAGES[*]}; install first:" >&2
        echo "  $BY_HAND" >&2
        exit 1
    fi
    if [ -n "$SUDO" ]; then
        if ! command -v sudo >/dev/null 2>&1; then
            echo "missing ${PACKAGES[*]}, and no sudo here; as root:" >&2
            echo "  ${BY_HAND#sudo }" >&2
            exit 1
        fi
        if [ ! -t 0 ]; then
            echo "missing ${PACKAGES[*]}; install first:" >&2
            echo "  $BY_HAND" >&2
            exit 1
        fi
        read -r -p "install ${PACKAGES[*]} with $BY_HAND? [y/N] " ANSWER
        case "$ANSWER" in
            [yY]|[yY][eE][sS]) ;;
            *) echo "not installed; run it by hand:" >&2; echo "  $BY_HAND" >&2; exit 1 ;;
        esac
    fi
    echo "=== installing ${PACKAGES[*]} ==="
    if ! { $SUDO apt-get update -qq && $SUDO apt-get install -y -qq "${PACKAGES[@]}"; }; then
        echo "could not install ${PACKAGES[*]}; install first:" >&2
        echo "  $BY_HAND" >&2
        exit 1
    fi
fi
ARCH="$(dpkg --print-architecture)"
# Its own scratch directory per architecture: a checkout shared with a Mac already has
# a .build, and one built for both architectures keeps both.
SCRATCH="$ROOT/.build-linux-$ARCH"
BINARY="$SCRATCH/release/kmap"

# ---------------------------------------------------------------- the build

cd "$ROOT"
if [ "${SKIP_BUILD:-}" != "1" ]; then
    echo "=== building ==="
    swift build -c release -Xswiftc -static-stdlib --scratch-path "$SCRATCH"
fi
[ -x "$BINARY" ] || { echo "no release binary at $BINARY" >&2; exit 1; }
VERSION="$("$BINARY" --version | sed 's/^kmap //; s/ .*//')"

# ---------------------------------------------------------------- the layout

STAGE="$SCRATCH/deb/kmap_${VERSION}_${ARCH}"
rm -rf "$SCRATCH/deb"
mkdir -p "$STAGE/DEBIAN" "$STAGE/usr/bin" "$STAGE/usr/share/doc/kmap" \
         "$STAGE/usr/share/applications" "$OUT"

install -m 755 "$BINARY" "$STAGE/usr/bin/kmap"

# Shared-library dependencies are read out of the binary by dpkg-shlibdeps rather than
# listed by hand: -static-stdlib links the Swift runtime in but leaves libcurl, libxml2
# and zlib outside. It insists on a source tree with debian/control; without one it
# prints nothing and the dependency list comes out empty.
SHLIBDEPS="$SCRATCH/shlibdeps"
rm -rf "$SHLIBDEPS"
mkdir -p "$SHLIBDEPS/debian"
printf 'Source: kmap\nPackage: kmap\nArchitecture: any\n' > "$SHLIBDEPS/debian/control"
DEPENDS=$(cd "$SHLIBDEPS" && dpkg-shlibdeps -O "$STAGE/usr/bin/kmap" 2> errors \
          | sed 's/^shlibs:Depends=//')
if [ -z "$DEPENDS" ]; then
    echo "dpkg-shlibdeps could not work out what this binary needs:" >&2
    sed 's/^/  /' "$SHLIBDEPS/errors" >&2
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
    PNG="$ROOT/Assets/app-icon/png/kmap-$SIZE.png"
    [ -f "$PNG" ] || continue
    DEST="$STAGE/usr/share/icons/hicolor/${SIZE}x${SIZE}/apps"
    mkdir -p "$DEST"
    install -m 644 "$PNG" "$DEST/kmap.png"
done
if [ -f "$ROOT/Assets/app-icon/kmap.svg" ]; then
    mkdir -p "$STAGE/usr/share/icons/hicolor/scalable/apps"
    install -m 644 "$ROOT/Assets/app-icon/kmap.svg" \
            "$STAGE/usr/share/icons/hicolor/scalable/apps/kmap.svg"
fi

cp "$ROOT/README.md" "$STAGE/usr/share/doc/kmap/README.md"
gzip -9n "$STAGE/usr/share/doc/kmap/README.md"

# ---------------------------------------------------------------- the package

# The oldest glibc the binary will start against, read out of the binary.
FLOOR=$(objdump -T "$STAGE/usr/bin/kmap" 2>/dev/null \
        | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sort -V -u | tail -1)
echo "needs at least ${FLOOR:-an unknown glibc}"

find "$STAGE" -type d -exec chmod 755 {} +
dpkg-deb --root-owner-group --build "$STAGE" > /dev/null
DEB="$OUT/kmap_${VERSION}_${ARCH}.deb"
mv "${STAGE}.deb" "$DEB"
echo "built $DEB"
dpkg-deb --info "$DEB" | sed -n '1,12p'
