#!/bin/bash
# kmap.app and a .dmg to drag it out of.
#
# kmap is a terminal program, so the bundle's executable is a small launcher that opens
# Terminal on the real binary in Resources. For a terminal-only install use `make install`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/build/mac"
APP="$OUT/kmap.app"

if [ "$(uname)" != "Darwin" ]; then
    echo "this builds a Mac application, and needs a Mac to build it on" >&2
    exit 1
fi

cd "$ROOT"
# One universal binary for Intel and Apple silicon; SwiftPM puts it under .build/apple.
if [ "${SKIP_BUILD:-}" != "1" ]; then
    echo "building for arm64 and x86_64..."
    swift build -c release --arch arm64 --arch x86_64
fi
BINARY="$ROOT/.build/apple/Products/Release/kmap"
[ -x "$BINARY" ] || { echo "no release binary at $BINARY" >&2; exit 1; }
echo "binary: $(lipo -archs "$BINARY" 2>/dev/null || echo "one architecture")"
VERSION="$("$BINARY" --version | sed 's/^kmap //; s/ .*//')"

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# The program itself; the launcher below carries the bundle's name.
cp "$BINARY" "$APP/Contents/Resources/kmap"

ICON="$ROOT/Assets/app-icon/kmap.icns"
if [ -f "$ICON" ]; then
    cp "$ICON" "$APP/Contents/Resources/kmap.icns"
else
    echo "note: no Assets/app-icon/kmap.icns — the bundle will get the generic icon"
fi

cat > "$APP/Contents/MacOS/kmap" <<'LAUNCHER'
#!/bin/bash
# Opens Terminal on the binary in Resources. `open -a` needs no automation permission.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec open -a Terminal "$here/../Resources/kmap"
LAUNCHER
chmod +x "$APP/Contents/MacOS/kmap"

# CFBundleIconFile only when the file exists; naming a missing one gets a console warning.
if [ -f "$APP/Contents/Resources/kmap.icns" ]; then
    ICON_KEY="    <key>CFBundleIconFile</key>       <string>kmap</string>"
else
    ICON_KEY=""
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>kmap</string>
    <key>CFBundleDisplayName</key>     <string>kmap</string>
    <key>CFBundleIdentifier</key>      <string>uk.kmap.kmap</string>
    <key>CFBundleVersion</key>         <string>$VERSION</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundleExecutable</key>      <string>kmap</string>
$ICON_KEY
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <!-- Nothing to show in the Dock: the window belongs to Terminal. -->
    <key>LSBackgroundOnly</key>        <false/>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: keeps an arm64 bundle from being killed outright on Apple silicon.
# Not a Developer ID signature, so Gatekeeper still asks the first time.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
    echo "note: could not sign the bundle; it will still run, with a warning"

echo "built $APP"

# The disk image: the bundle on the left, an Applications link on the right.
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT/kmap-$VERSION.dmg"
hdiutil create -quiet -volname "kmap $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

echo "built $DMG"
echo
echo "For a terminal-only install, with no bundle: make install"
