// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "kmap",
    // A floor for the Apple platforms, not a fence around them: SwiftPM reads
    // this only where it applies, and the package builds on Linux — which is
    // where kmap is expected to run under WSL — without an entry of its own.
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // Deflate and inflate, of whole buffers, which is all kmap compresses. The
        // sources come with kmap on every platform, so a tile is the same bytes
        // whichever machine wrote it. See Sources/CLibdeflate/README.md.
        .target(
            name: "CLibdeflate",
            path: "Sources/CLibdeflate",
            exclude: ["README.md", "COPYING"],
            // Upstream's code, unmodified, under upstream's warning flags and not ours.
            cSettings: [.unsafeFlags(["-w"])]
        ),
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
        // The loops written in NEON and SSE4.1. They turn on moving bytes about inside
        // a vector, which Swift's SIMD types have no way to say.
        .target(
            name: "CVector",
            path: "Sources/CVector"
        ),
        .executableTarget(
            name: "kmap",
            dependencies: ["CLibdeflate", "CStbImage", "CVector"],
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
        // Mirrors the source tree: Tests/OSM/PBF/ProtoReaderTests.swift tests
        // Sources/kmap/OSM/PBF/ProtoReader.swift.
        .testTarget(
            name: "kmapTests",
            dependencies: ["kmap"],
            path: "Tests"
        )
    ]
)
