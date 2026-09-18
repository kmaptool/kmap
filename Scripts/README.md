# Packaging

One script per platform, run on that platform. They make the release files; using or
developing kmap needs none of them, and `make install` puts the binary on the PATH
without a bundle, an installer or a package manager.

| script | on | makes |
|---|---|---|
| `build-mac.sh` | macOS | `build/mac/kmap.app`, `build/mac/kmap-<version>.dmg` |
| `build-debian.sh` | Debian or Ubuntu | `build/debian/kmap_<version>_<arch>.deb` |
| `build-linux.sh` | Amazon Linux 2 | `build/linux/kmap-<version>-linux-<arch>.tar.xz`, for every other Linux |
| `build-windows.sh` | Windows, from Git Bash | `build/windows/kmap-<version>.exe` |

`make package-mac`, `make package-debian`, `make package-linux` and `make package-windows`
call them. Each script refuses on the wrong OS and names any tool it is missing.
`SKIP_BUILD=1` packages what was built last time; on Windows the same is `-SkipBuild`.

## Requirements

| | |
|---|---|
| macOS | Xcode or its command line tools. The bundle is signed ad-hoc: Gatekeeper asks once on first launch. |
| Debian | The Swift toolchain, `dpkg-dev` and `binutils`. The last two the script installs through apt: outright as root, after asking otherwise, and never with `SKIP_APT=1`. Build on the oldest base you mean to support: a binary built against an older glibc runs on newer ones, not the reverse. Ubuntu 20.04 (glibc 2.31, also Debian 11's) covers everything since. |
| Linux | The Swift toolchain, `tar`, `xz` and `binutils`. The last three the script installs through dnf or yum when run as root, and never with `SKIP_INSTALL=1`. Build on Amazon Linux 2. Ubuntu's libcurl tags its symbols with a version; a binary built against it asks for those tags, and the loader of every distribution whose libcurl has none prints a warning on each run. Amazon Linux 2 has no tags to ask for, and its glibc 2.26 is older than any distribution still in use. The script checks the finished binary and refuses one that asks for versioned libcurl symbols. |
| Windows 10 1803+ | The Swift toolchain, Visual Studio Build Tools, the Windows SDK and [Inno Setup](https://jrsoftware.org/isinfo.php). Without Inno Setup the script stages a folder that runs as it is. |

## Folders

Everything is written inside the checkout, and every path here is in `.gitignore`.

| | scratch | output |
|---|---|---|
| macOS | `.build/` | `build/mac/` |
| Debian | `.build-linux-<arch>/` | `build/debian/` |
| Linux | `.build-portable-<arch>/` | `build/linux/` |
| Windows | `.build-windows-<arch>/` | `build/windows/` |

Debian, Linux and Windows keep out of `.build/`: a checkout also built on a Mac has
`.build/release` as a symlink into `arm64-apple-macosx`, which is no place for another
platform's binary. The two Linux builds keep apart as well: they are built against
different systems and must not share objects.

The Windows checkout has to be on a local disk. From a folder shared by a Mac, mapped to
a drive letter or not, SwiftPM resolves the path to its UNC form and stops:

    Fatal error: invalid absolute path 'UNC\Mac\apps\kmap\Package.swift'

## Architectures

| | |
|---|---|
| macOS | One universal binary (`swift build --arch arm64 --arch x86_64`), so one `.app` and one `.dmg`. |
| Debian | One `.deb` per architecture, each built on a machine of that architecture: real, virtual or a container. Both builds keep their own scratch folder, so one checkout serves both. |
| Linux | One `.tar.xz` per architecture, built the same way. The name carries the architecture as those distributions spell it: `x86_64`, `aarch64`. |
| Windows | One installer carrying both, built from either kind of machine. Inno Setup lays down the payload matching the machine it installs on. |

A file name without an architecture runs on anything that platform has. A Windows build
that found only one architecture's libraries is named `kmap-<version>-<arch>.exe`.

### Windows, both architectures from one machine

`VsDevCmd -arch=<target>` cannot be used: SwiftPM compiles and links `Package.swift` for
the toolchain's own architecture, so an environment pointed at the other one fails before
it reaches kmap:

    lld-link: error: msvcrt.lib(chkstk.obj): machine type x64 conflicts with arm64

The script keeps the host's environment and hands the target's MSVC, Windows SDK and Swift
SDK libraries to the product link with `/LIBPATH:`, which `lld-link` reads before `LIB`.

The target's Swift runtime comes from the toolchain's redistributable merge modules,
`Redistributables\<version>\rtl.<arch>.msm`: the cab is extracted with the Windows SDK's
`MsiDb`, expanded, and the file names restored from the File table. Microsoft's C runtime
comes from Visual Studio's `VC\Redist`.

`rtl.<arch>.msm`, not `rtl.shared.<arch>.msm`. The shared variant carries a `swiftCore.dll`
missing symbols the SDK's import library promises, among them the thunks for
`Encodable.encode(to:)`. A binary shipped with it installs and then dies on launch:

    kmap.exe - the procedure entry point $sSE6encode2toys7Encoder_p_tKFTq
    could not be located in the dynamic link library

Before packaging, every symbol `kmap.exe` imports from a shipped DLL is checked against
that DLL's exports, so a wrong runtime stops the build instead of the user.

The other architecture needs its MSVC libraries and Windows SDK, a checkbox in the Visual
Studio installer. Without them the script names the missing folder and packages the one
architecture it has.

## Icons

One drawing in `Assets/app-icon/`, in the form each platform asks for. Every script works
without them.

| file | used as |
|---|---|
| `kmap.icns` | the Mac bundle's icon |
| `kmap.ico` | compiled into `kmap.exe` with its version; the installer, shortcuts and Add or Remove Programs entry |
| `png/kmap-<size>.png` | `/usr/share/icons/hicolor/<size>x<size>/apps/kmap.png`, which `Icon=kmap` in the `.desktop` entry resolves against |
| `kmap.svg` | the same, under `scalable/` |
