// The one translation unit that turns stb_image.h into code.
//
// stb_image is a single public-domain header that reads PNG, JPEG, BMP and GIF —
// the formats a person actually hands to an icon importer — and it is here because
// the alternative was ImageIO, which exists only on Apple's platforms. One decoder
// on both means an icon imported under Linux and the same icon imported on a Mac
// produce the same drawing, which for a file that ends up inside a map matters more
// than either platform's own library does.
//
// The switches that decide which formats are compiled in live in Package.swift, so
// this file and the header Swift sees cannot disagree about them.
//
// Vendored verbatim at v2.30. Do not edit include/stb_image.h: to update it, replace
// the file wholesale and run the suite, which reads real pictures back out again.
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
