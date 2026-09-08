# Packaging

Three scripts, one per platform, each producing what somebody on that platform expects to
be handed. They are for making a release; nobody needs them to use or develop kmap.

```sh
Scripts/build-mac.sh              # -> build/mac/kmap.app and kmap-<version>.dmg
Scripts/build-debian.sh           # -> build/debian/kmap_<version>_<arch>.deb
Scripts/build-windows.sh          # -> build/windows/kmap-<version>.exe
```

`make package-mac`, `make package-debian` and `make package-windows` call the same three.

## One folder serves all three

Everything is built inside the project folder and nothing is written outside it. Each
platform keeps to its own names, so one checkout does not become two toolchains fighting
over one directory:

| | scratch | output |
|---|---|---|
| macOS | `.build/` | `build/mac/` |
| Debian | inside the container, on its own disk | `build/debian/` |
| Windows | `.build-windows-<arch>/` | `build/windows/` |

Windows keeps out of the plain `.build` on purpose: a checkout also built on a Mac has
`.build/release` as a symlink into `arm64-apple-macosx`, which is neither a place a
Windows binary can be written nor a place one can be found. Every one of these paths is
ignored by git.

**The Windows checkout has to be on a local disk.** A folder shared from a Mac — over a
Parallels share or the network, mapped to a drive letter or not — is not enough: SwiftPM
resolves the path back to its UNC form and stops before it reads anything.

    Fatal error: invalid absolute path 'UNC\Mac\apps\kmap\Package.swift'

So a Mac and a Windows machine cannot share one working copy for this. Copy or clone the
source onto the Windows machine's own disk and build it there.

## `make install` is still the base

```sh
make install            # -> /usr/local/bin/kmap
make install PREFIX=~/.local
```

That is the whole install for anybody who lives in a terminal: one binary, on the PATH.
The packages exist for the people who do not, and neither way is the "real" one. On
Windows the equivalent is the installer's *Add kmap to PATH* box.

## Architectures

| | |
|---|---|
| macOS | **one file for both.** `swift build --arch arm64 --arch x86_64` gives a universal binary, so there is one `.app` and one `.dmg`. |
| Debian | **one `.deb` per architecture.** `Scripts/build-debian.sh amd64 arm64` makes both from one machine — the foreign one under emulation, roughly ten times slower. |
| Windows | **one installer carrying both**, from either kind of machine. Inno Setup lays down the payload that matches the machine it is installing on. |

No architecture in a file name means the file runs on anything that platform has; an
architecture in the name means the machine has to match. A Windows build that found only
one architecture's libraries comes out as `kmap-<version>-x64.exe` for that reason.

### Windows, both architectures from one machine

`VsDevCmd -arch=<target>` cannot be used: SwiftPM compiles and links `Package.swift` for
the toolchain's own architecture, so an environment pointed at the other one fails before
it reaches kmap with

    lld-link: error: msvcrt.lib(chkstk.obj): machine type x64 conflicts with arm64

and Swift for Windows ships no SDK to cross-compile with. The script therefore leaves the
environment on the host's architecture and hands the target's libraries to the product
link with `/LIBPATH:`, which `lld-link` reads before the `LIB` variable.

The target's Swift runtime comes out of the toolchain's redistributable merge modules,
`Redistributables\<version>\rtl.{amd64,arm64}.msm`: the script extracts the cab with the
Windows SDK's `MsiDb`, expands it, and restores the file names from the File table.
Microsoft's C runtime comes from Visual Studio's `VC\Redist`, per architecture.

**`rtl.<arch>.msm`, not `rtl.shared.<arch>.msm`.** The toolchain ships several variants of
the redistributable side by side and they are not one build in different wrappings. The
shared one carries a `swiftCore.dll` that does not export everything the SDK's import
library promises — `$sSE6encode2toys7Encoder_p_tKFTj` and `...Tq`, the dispatch thunk and
method descriptor for `Encodable.encode(to:)`, are absent from it. A binary linked against
the SDK and shipped with that DLL installs cleanly and then dies on launch:

    kmap.exe - the procedure entry point $sSE6encode2toys7Encoder_p_tKFTq
    could not be located in the dynamic link library

`rtl.<arch>.msm` matches the SDK, and for the host architecture matches the installed
runtime byte for byte, which is how it was told apart from the other.

For that the machine needs the *other* architecture's MSVC libraries and Windows SDK — a
checkbox in the Visual Studio installer. Without them the script says which folder it
could not find and packages the one architecture it has.

## What each one needs

**macOS** — Xcode's toolchain. The bundle is signed ad-hoc, which keeps an ARM64 binary
from being killed on Apple silicon; it is not a Developer ID signature and Gatekeeper
still asks the first time.

**Debian** — Docker. The build happens in `swift:6.0-focal`, the oldest base Swift still
publishes: a binary built against an older glibc runs on newer ones and not the other way
round, and Ubuntu 20.04's glibc 2.31 is also Debian 11's. The dependencies are read out of
the binary by `dpkg-shlibdeps`, since `-static-stdlib` links the Swift runtime in but
leaves libcurl, libxml2 and zlib outside; the script stops rather than guess.

**Windows 10 1803 or later** — the Swift toolchain, Visual Studio Build Tools (the linker
and both architectures' libraries), the Windows SDK, and
[Inno Setup](https://jrsoftware.org/isinfo.php). Without Inno Setup the script still
stages a folder that runs as it stands. Swift for Windows has no static standard library,
so the runtime travels beside the binary; the script copies only the DLLs the binary
actually imports, transitively.

## Icons

One drawing, in `Assets/app-icon/`, in the form each platform asks for:

| | |
|---|---|
| `kmap.icns` | the Mac bundle's `CFBundleIconFile` |
| `kmap.ico` | compiled into kmap.exe as its icon and version, and used by the installer, the shortcuts and the Add-or-Remove-Programs entry |
| `png/kmap-<size>.png` | `/usr/share/icons/hicolor/<size>x<size>/apps/kmap.png`, which `Icon=kmap` in the `.desktop` entry resolves against |
| `kmap.svg` | the same, under `scalable/` |

Every script works without them; each checks the file is there before naming it.
