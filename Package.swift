// swift-tools-version:5.9
import PackageDescription

// zlib, the same module either way.
//
// On the Unixes it is the system's own: macOS ships it in the SDK and every Linux
// in libz-dev, and the one kmap wants is the one the rest of the machine is
// already using. Windows has none and nowhere to send somebody for one — kmap
// arrives there as an installer and an .exe, and a person who wants a Garmin map
// should not have to set up vcpkg first — so there the sources come with it. See
// Sources/CZlibVendored/README.md.
//
// The condition is on the host because that is what a Windows build is built on;
// nothing here cross-compiles.
#if os(Windows)
let zlib: Target = .target(
    name: "CZlib",
    path: "Sources/CZlibVendored",
    exclude: ["README.md", "LICENSE-zlib"]
)
#else
let zlib: Target = .systemLibrary(
    name: "CZlib",
    path: "Sources/CZlib"
)
#endif

let package = Package(
    name: "kmap",
    // A floor for the Apple platforms, not a fence around them: SwiftPM reads
    // this only where it applies, and the package builds on Linux — which is
    // where kmap is expected to run under WSL — without an entry of its own.
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        zlib,
        // The image decoder, vendored. See Sources/CStbImage/stb_image.c for why it is
        // here rather than ImageIO, and Sources/kmap/Core/Raster.swift for what kmap
        // asks of it.
        //
        // The formats are chosen here so the implementation and the header Swift reads
        // cannot disagree: PNG, JPEG, BMP and GIF are what an icon arrives as, and the
        // rest of stb's list is surface with no caller. STBI_NO_STDIO because the bytes
        // are read in Swift and handed over — a decoder should not also be opening files
        // by name, least of all names with a Cyrillic path in them.
        .target(
            name: "CStbImage",
            path: "Sources/CStbImage",
            cSettings: [
                .define("STBI_NO_STDIO"),
                .define("STBI_NO_PSD"),
                .define("STBI_NO_HDR"),
                .define("STBI_NO_PIC"),
                .define("STBI_NO_PNM"),
                .define("STBI_NO_TGA")
                // `STBI_THREAD_LOCAL` is deliberately not defined here. stb picks the
                // spelling itself — `_Thread_local` for C11, `__declspec(thread)` for
                // MSVC, `__thread` for older GCC — and a define from the command line
                // collides with whichever it chose, which is a warning on every platform
                // and the wrong keyword on one. Left alone, `stbi_failure_reason()` is
                // still per-thread, which is all this was ever asking for.
            ]
        ),
        .executableTarget(
            name: "kmap",
            dependencies: ["CZlib", "CStbImage"],
            path: "Sources/kmap",
            linkerSettings: [
                // Where Windows keeps the dialogs kmap shows itself, rather than through a
                // helper process: comdlg32 the open dialog, shell32 the folder browser,
                // ole32 what frees its answer, user32 the message that opens it at a
                // folder. See Core/Files/WindowsFileDialog.swift.
                .linkedLibrary("comdlg32", .when(platforms: [.windows])),
                .linkedLibrary("shell32", .when(platforms: [.windows])),
                .linkedLibrary("ole32", .when(platforms: [.windows])),
                .linkedLibrary("user32", .when(platforms: [.windows]))
            ]
        ),
        // Mirrors the source tree: Tests/OSM/PBF/ProtobufTests.swift tests
        // Sources/kmap/OSM/PBF/Protobuf.swift.
        .testTarget(
            name: "kmapTests",
            dependencies: ["kmap"],
            path: "Tests"
        )
    ]
)
