#!/bin/bash
# A .tar.xz of kmap for every Linux that is not Debian or Ubuntu: Arch, Fedora, openSUSE
# and the rest. Built on Amazon Linux 2: a real machine, a virtual one or a container.
# The machine's own architecture; the other one is built the same way on a machine of
# that architecture.
#
# Why there and not on Ubuntu: Ubuntu's libcurl tags its symbols with a version, a binary
# built against it asks for those tags, and every other distribution's libcurl, which has
# none, makes the loader print a warning on each run. Amazon Linux 2 has no tags to ask
# for, and its glibc 2.26 is older than any distribution still in use.
#
# The binary is linked with a static Swift standard library and needs only glibc, libcurl
# and zlib, which every distribution carries.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/build/linux"

# ---------------------------------------------------------------- the machine

if [ "$(uname -s)" != "Linux" ]; then
    echo "this builds a Linux archive, and needs Linux to build it on" >&2
    exit 1
fi
if ! command -v swift >/dev/null 2>&1; then
    echo "missing:" >&2
    echo "  swift (swift.org/install/linux)" >&2
    exit 1
fi
# The archive tools. As root they are installed outright; otherwise, or with
# SKIP_INSTALL=1, the script says what is missing and stops.
PACKAGES=()
command -v tar >/dev/null 2>&1 || PACKAGES+=(tar)
command -v xz >/dev/null 2>&1 || PACKAGES+=(xz)
command -v objdump >/dev/null 2>&1 || PACKAGES+=(binutils)
if [ ${#PACKAGES[@]} -gt 0 ]; then
    INSTALLER="$(command -v dnf || command -v yum || true)"
    if [ "$(id -u)" -ne 0 ] || [ -z "$INSTALLER" ] || [ "${SKIP_INSTALL:-}" = "1" ]; then
        echo "missing:" >&2
        printf '  %s\n' "${PACKAGES[@]}" >&2
        exit 1
    fi
    echo "=== installing ${PACKAGES[*]} ==="
    if ! "$INSTALLER" install -y -q "${PACKAGES[@]}" >/dev/null; then
        echo "could not install ${PACKAGES[*]}; install first:" >&2
        echo "  $(basename "$INSTALLER") install ${PACKAGES[*]}" >&2
        exit 1
    fi
fi
MACHINE="$(uname -m)"
# Its own scratch directory per architecture, apart from the Debian build's: the two are
# built against different systems and must not share objects.
SCRATCH="$ROOT/.build-portable-$MACHINE"
BINARY="$SCRATCH/release/kmap"

# ---------------------------------------------------------------- the build

cd "$ROOT"
if [ "${SKIP_BUILD:-}" != "1" ]; then
    echo "=== building ==="
    swift build -c release -Xswiftc -static-stdlib --scratch-path "$SCRATCH"
fi
[ -x "$BINARY" ] || { echo "no release binary at $BINARY" >&2; exit 1; }
VERSION="$("$BINARY" --version | sed 's/^kmap //; s/ .*//')"

# The point of building here: no versioned libcurl symbols, so no loader warning on the
# distributions whose libcurl has none. The symbol table is read once and searched from a
# variable: `objdump | grep -q` under pipefail reports a match as a failure, since grep
# leaves at the first one and objdump dies of the closed pipe.
SYMBOLS="$(objdump -T "$BINARY")"
if grep -q 'CURL_[A-Z]' <<<"$SYMBOLS"; then
    echo "the binary asks for versioned libcurl symbols; build it on Amazon Linux 2" >&2
    exit 1
fi
# The oldest glibc the binary will start against.
FLOOR=$(grep -oE 'GLIBC_[0-9]+\.[0-9]+' <<<"$SYMBOLS" | sort -V -u | tail -1)
echo "needs at least ${FLOOR:-an unknown glibc}"

# ---------------------------------------------------------------- the archive

# Underscores, as the .deb has them, so a release lists the archives right after the
# packages; the architecture as those distributions name it, x86_64 and aarch64.
NAME="kmap_${VERSION}_linux_${MACHINE}"
STAGE="$SCRATCH/archive/$NAME"
rm -rf "$SCRATCH/archive"
mkdir -p "$STAGE" "$OUT"
install -m 755 "$BINARY" "$STAGE/kmap"
install -m 644 "$ROOT/LICENSE" "$ROOT/NOTICE.md" "$ROOT/README.md" "$STAGE/"
ARCHIVE="$OUT/$NAME.tar.xz"
tar -C "$SCRATCH/archive" --owner=0 --group=0 --numeric-owner -cJf "$ARCHIVE" "$NAME"
echo "built $ARCHIVE"
